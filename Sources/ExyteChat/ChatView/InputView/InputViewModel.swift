//
//  Created by Alex.M on 20.06.2022.
//

import Foundation
import Combine
import ExyteMediaPicker

public final class InputViewModel: ObservableObject {
    
    @Published public var attachments = InputViewAttachments()
    @Published public var state: InputViewState = .empty

    @Published var showPicker = false
    @Published public var showRoshambo = false
    @Published public var showGiphy = false
    @Published public var mediaPickerMode = MediaPickerMode.photos

    @Published var showActivityIndicator = false

    public var recordingPlayer: RecordingPlayer?
    var didSendMessage: ((DraftMessage) -> Void)?

    private var recorder = Recorder()

    private var recordPlayerSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()

    public init() {
        
    }

    func onStart() {
        subscribeValidation()
        subscribePicker()
        subscribeGiphy()
        subscribeRoshambo()
    }

    func onStop() {
        subscriptions.removeAll()
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.attachments = InputViewAttachments()
            self?.showPicker = false
            self?.state = .empty
        }
    }

    func send() {
        recorder.stopRecording()
        recordingPlayer?.reset()
        sendMessage()
            .store(in: &subscriptions)
    }

    public func inputViewAction() -> (InputViewAction) -> Void {
        { [weak self] in
            self?.inputViewActionInternal($0)
        }
    }

    func inputViewActionInternal(_ action: InputViewAction) {
        switch action {
        case .photo:
            mediaPickerMode = .photos
            showPicker = true
        case .add:
            mediaPickerMode = .camera
        case .camera:
            mediaPickerMode = .camera
            showPicker = true
        case .send:
            send()
        case .recordAudioTap:
            state = recorder.isAllowedToRecordAudio ? .isRecordingTap : .waitingForRecordingPermission
            recordAudio()
        case .recordAudioHold:
            state = recorder.isAllowedToRecordAudio ? .isRecordingHold : .waitingForRecordingPermission
            recordAudio()
        case .recordAudioLock:
            state = .isRecordingTap
        case .stopRecordAudio:
            recorder.stopRecording()
            if let _ = attachments.recording {
                state = .hasRecording
            }
            recordingPlayer?.reset()
        case .deleteRecord:
            unsubscribeRecordPlayer()
            recorder.stopRecording()
            attachments.recording = nil
        case .playRecord:
            state = .playingRecording
            if let recording = attachments.recording {
                subscribeRecordPlayer()
                recordingPlayer?.play(recording)
            }
        case .pauseRecord:
            state = .pausedRecording
            recordingPlayer?.pause()
        case .roshambo:
            showRoshambo = true
        case .giphy:
            showGiphy = true
        }
    }

    func recordAudio() {
        if recorder.isRecording {
            return
        }
        Task { @MainActor in
            attachments.recording = Recording()
            let url = await recorder.startRecording { duration, samples in
                DispatchQueue.main.async { [weak self] in
                    self?.attachments.recording?.duration = duration
                    self?.attachments.recording?.waveformSamples = samples
                }
            }
            if state == .waitingForRecordingPermission {
                state = .isRecordingTap
            }
            attachments.recording?.url = url
        }
    }
}

private extension InputViewModel {

    func validateDraft() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.attachments.text.isEmpty || !self.attachments.medias.isEmpty {
                self.state = .hasTextOrMedia
            } else if self.attachments.text.isEmpty,
                      self.attachments.medias.isEmpty,
                      self.attachments.recording == nil,
                      self.attachments.giphyId == nil {
                self.state = .empty
            }
        }
    }

    func subscribeValidation() {
        $attachments.sink { [weak self] _ in
            self?.validateDraft()
        }
        .store(in: &subscriptions)
    }

    func subscribePicker() {
        $showPicker
            .sink { [weak self] value in
                if !value {
                    self?.attachments.medias = []
                }
            }
            .store(in: &subscriptions)
    }

    func subscribeRecordPlayer() {
        recordPlayerSubscription = recordingPlayer?.didPlayTillEnd
            .sink { [weak self] in
                self?.state = .hasRecording
            }
    }

    func unsubscribeRecordPlayer() {
        recordPlayerSubscription = nil
    }
    
    func subscribeGiphy() {
        $showGiphy
            .sink { [weak self] value in
                if !value {
                    self?.attachments.giphyId = nil
                }
            }
            .store(in: &subscriptions)
    }
    
    func subscribeRoshambo() {
//        $showRoshambo
//            .sink { [weak self] value in
//                if !value {
//                    self?.attachments.giphyId = nil
//                }
//            }
//            .store(in: &subscriptions)
    }
}

private extension InputViewModel {
    
    func mapAttachmentsForSend() -> AnyPublisher<[Attachment], Never> {
        attachments.medias.publisher
            .receive(on: DispatchQueue.global())
            .asyncMap { media in
                guard let thumbnailURL = await media.getThumbnailURL() else {
                    return nil
                }

                switch media.type {
                case .image:
                    return Attachment(id: UUID().uuidString, url: thumbnailURL, type: .image)
                case .video:
                    guard let fullURL = await media.getURL() else {
                        return nil
                    }
                    return Attachment(id: UUID().uuidString, thumbnail: thumbnailURL, full: fullURL, type: .video)
                }
            }
            .compactMap {
                $0
            }
            .collect()
            .eraseToAnyPublisher()
    }

    func sendMessage() -> AnyCancellable {
        showActivityIndicator = true
        return mapAttachmentsForSend()
            .compactMap { [attachments] _ in
                DraftMessage(
                    text: attachments.text,
                    medias: attachments.medias,
                    recording: attachments.recording,
                    replyMessage: attachments.replyMessage,
                    createdAt: Date(),
                    giphyId: attachments.giphyId
                )
            }
            .sink { [weak self] draft in
                DispatchQueue.main.async { [self, draft] in
                    self?.showActivityIndicator = false
                    self?.didSendMessage?(draft)
                    self?.reset()
                }
            }
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
