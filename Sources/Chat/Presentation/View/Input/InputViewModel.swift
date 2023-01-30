//
//  Created by Alex.M on 20.06.2022.
//

import Foundation
import Combine
import MediaPicker

final class InputViewModel: ObservableObject {
    
    @Published var text: String = ""
    @Published var medias: [Media] = []
    @Published var showPicker = false

    @Published var canSend = false

    var didSendMessage: ((DraftMessage) -> Void)?

    private var subscriptions = Set<AnyCancellable>()

    init() {

    }

    func onStart() {
        subscribeValidation()
        subscribePicker()
    }

    func onStop() {
        subscriptions.removeAll()
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.text = ""
            self?.medias = []
            self?.showPicker = false
        }
    }

    func send() {
        sendMessage()
            .store(in: &subscriptions)
    }

    func validateDraft() {
        let notEmptyTextInChatWindow = !text.isEmpty && !showPicker
        let notEmptyMediasInPickerWindow = !medias.isEmpty && showPicker
        canSend = notEmptyTextInChatWindow || notEmptyMediasInPickerWindow
    }
}

private extension InputViewModel {
    
    func mapAttachmentsForSend() -> AnyPublisher<[any Attachment], Never> {
        medias.publisher
            //.receive(on: DispatchQueue.global())
            .asyncMap { media in
                await (media, media.getUrl())
                    //.map { url in (media, url) }
            }
            .compactMap { (media, url) -> (Media, URL)? in
                guard let url = url else { return nil }
                return (media, url)
            }
            .map { (media, url) -> any Attachment in
                switch media.type {
                case .image:
                    return ImageAttachment(url: url)
                case .video:
                    return VideoAttachment(url: url)
                }
            }
            .collect()
            .eraseToAnyPublisher()
    }

    func sendMessage() -> AnyCancellable {
        mapAttachmentsForSend()
            .compactMap { [text] in
                DraftMessage(
                    text: text,
                    attachments: $0,
                    createdAt: Date()
                )
            }
            .sink { draft in
                DispatchQueue.main.async { [weak self, draft] in
                    self?.didSendMessage?(draft)
                    self?.reset()
                }
            }
    }

    func subscribeValidation() {
        let textTrigger = $text.map { _ in }
        let mediasTrigger = $medias.map { _ in }

        textTrigger
            .merge(with: mediasTrigger)
            .sink { [weak self] in
                self?.validateDraft()
            }
            .store(in: &subscriptions)
    }

    func subscribePicker() {
        $showPicker
            .sink { [weak self] value in
                if !value {
                    self?.medias = []
                }
            }
            .store(in: &subscriptions)
    }
}

extension Publisher {
    func asyncMap<T>(
        _ transform: @escaping (Output) async -> T
    ) -> Publishers.FlatMap<Future<T, Never>, Self> {
        flatMap { value in
            Future { promise in
                Task {
                    let output = await transform(value)
                    promise(.success(output))
                }
            }
        }
    }
}
