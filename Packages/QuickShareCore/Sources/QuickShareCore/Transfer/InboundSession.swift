import Foundation
import SwiftProtobuf

/// One incoming connection (we are the receiver / server). See PROTOCOL_NOTES §4–§8.
///
/// State machine: handshake → awaitingPairedKeyEncryption → awaitingPairedKeyResult → awaitingIntroduction
/// → awaitingDecision → receiving → done. Any frame that is not valid for the current state closes the connection.
actor InboundSession {
    enum State: Equatable {
        case handshaking
        case awaitingPairedKeyEncryption
        case awaitingPairedKeyResult
        case awaitingIntroduction
        case awaitingDecision
        case receiving
        case done
    }

    struct Configuration: Sendable {
        var identity: LocalIdentity
        var decisionTimeout: TimeInterval = 60
        /// Free space to keep on the destination volume.
        var reservedSpace: Int64 = 100 * 1024 * 1024
    }

    nonisolated let id = UUID()
    private let stream: ByteStream
    private let config: Configuration
    private let diagnostics: Diagnostics
    private let emit: @Sendable (TransferEvent) -> Void
    private let onFinish: @Sendable (UUID) -> Void
    private let tag: String

    private(set) var state: State = .handshaking
    private var stageDeadline: Date?
    private var transport: SecureTransport?
    private var assembler = BytesPayloadAssembler()

    private var fileMetadata: [Int64: (offer: FileOffer, folder: [String])] = [:]
    private var textMetadata: [Int64: TextOffer] = [:]
    private var writers: [Int64: IncomingFileWriter] = [:]
    private var outstanding: Set<Int64> = []
    private var createdFolders: [URL] = []
    private var totalBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var lastProgress = Date.distantPast

    private var keepAliveTask: Task<Void, Never>?
    private var decisionTask: Task<Void, Never>?

    init(stream: ByteStream, configuration: Configuration, diagnostics: Diagnostics,
         emit: @escaping @Sendable (TransferEvent) -> Void, onFinish: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.stream = stream
        config = configuration
        self.diagnostics = diagnostics
        self.emit = emit
        self.onFinish = onFinish
        tag = "in-\(id.uuidString.prefix(4))"
    }

    // MARK: Lifecycle

    func run() async {
        do {
            let (device, ukey) = try await Handshake.runServer(stream: stream, identity: config.identity,
                                                               diagnostics: diagnostics, tag: tag)
            let keys = SecureChannelKeys(nextSecret: ukey.nextSecret, role: .server)
            let transport = SecureTransport(stream: stream, keys: keys, diagnostics: diagnostics, tag: tag)
            self.transport = transport
            self.device = device
            pin = ukey.pin
            startKeepAlive()

            try await transport.send(SharingFrames.pairedKeyEncryption())
            enter(.awaitingPairedKeyEncryption, deadline: Limits.pairedKeyTimeout)

            while state != .done {
                let frame = try await receiveNext(transport)
                try await handle(frame, transport)
            }
        } catch {
            await fail(transferError(from: error), notifyPeer: false)
        }
    }

    private var device: RemoteDevice?
    private var pin = ""

    /// Accepts or declines a pending request. `destination` is required to accept.
    func respond(accept: Bool, destination: URL?) async {
        guard state == .awaitingDecision, let transport else { return }
        decisionTask?.cancel()
        guard accept, let destination else {
            diagnostics.info(tag, "user declined")
            try? await transport.send(SharingFrames.response(.reject))
            await finish(with: .failed(transferID: id, error: .declined), lingerSeconds: 2)
            return
        }
        do {
            try checkFreeSpace(at: destination)
            try prepareWriters(root: destination)
        } catch let error as TransferError {
            let status: Nearby_Sharing_Service_Proto_ConnectionResponseFrame.Status = error == .notEnoughSpace ? .notEnoughSpace : .reject
            try? await transport.send(SharingFrames.response(status))
            await fail(error, notifyPeer: false)
            return
        } catch {
            try? await transport.send(SharingFrames.response(.reject))
            await fail(transferError(from: error), notifyPeer: false)
            return
        }
        guard state == .awaitingDecision else { return }   // failed while preparing
        enter(.receiving, deadline: nil)
        diagnostics.info(tag, "accepted; expecting \(outstanding.count) payloads, \(totalBytes) bytes")
        do {
            try await transport.send(SharingFrames.response(.accept))
        } catch {
            await fail(transferError(from: error), notifyPeer: false)
        }
    }

    /// Cancels the transfer from our side.
    func cancel() async {
        guard state != .done else { return }
        await fail(.cancelledByUser, notifyPeer: true)
    }

    // MARK: Frame handling

    private func receiveNext(_ transport: SecureTransport) async throws -> OfflineFrame {
        var timeout = config.identity.options.idleTimeout
        var stage = "frame"
        if let stageDeadline {
            let remaining = stageDeadline.timeIntervalSinceNow
            if remaining <= 0 { throw TransportError.timedOut("\(state)") }
            if remaining < timeout { timeout = remaining; stage = "\(state)" }
        }
        let stream = self.stream
        return try await withTimeout(timeout, stage: stage, onTimeout: { stream.close() }) {
            try await transport.receive()
        }
    }

    private func handle(_ frame: OfflineFrame, _ transport: SecureTransport) async throws {
        guard frame.hasV1 else { return }
        switch frame.v1.type {
        case .keepAlive:
            if !frame.v1.keepAlive.ack { try await transport.send(OfflineFrames.keepAlive(ack: true)) }
        case .disconnection:
            diagnostics.info(tag, "peer sent DISCONNECTION in state \(state)")
            throw state == .awaitingDecision ? TransferError.cancelledByPeer : TransferError.connectionLost
        case .payloadTransfer:
            try await handlePayload(frame.v1.payloadTransfer, transport)
        case .bandwidthUpgradeNegotiation:
            let upgrade = frame.v1.bandwidthUpgradeNegotiation
            if upgrade.eventType == .upgradePathAvailable, config.identity.options.rejectBandwidthUpgrade {
                diagnostics.info(tag, "declining bandwidth upgrade to \(upgrade.upgradePathInfo.medium)")
                try await transport.send(OfflineFrames.upgradeFailure(medium: upgrade.upgradePathInfo.medium))
            }
        default:
            diagnostics.debug(tag, "ignoring \(frame.v1.type)")
        }
    }

    private func handlePayload(_ payload: PayloadTransferFrame, _ transport: SecureTransport) async throws {
        if payload.packetType == .control {
            let event = payload.controlMessage.event
            diagnostics.info(tag, "peer control message \(event)")
            if event == .payloadCanceled || event == .payloadError { throw TransferError.cancelledByPeer }
            return
        }
        switch payload.payloadHeader.type {
        case .bytes:
            guard let (payloadID, data) = try assembler.add(payload) else { return }
            if let text = textMetadata[payloadID] {
                guard state == .receiving, outstanding.contains(payloadID) else {
                    throw TransferError.protocolViolation("text payload outside receiving state")
                }
                let string = String(decoding: data, as: UTF8.self)
                emit(.receivedText(transferID: id, text: string, kind: text.kind))
                receivedBytes += Int64(data.count)
                try await completePayload(payloadID)
            } else {
                guard let sharing = try? SharingFrame(serializedBytes: data), sharing.hasV1 else {
                    throw TransferError.protocolViolation("undecodable sharing frame")
                }
                diagnostics.debug(tag, "← sharing \(sharing.logDescription)")
                try await handleSharing(sharing, transport)
            }
        case .file:
            let payloadID = payload.payloadHeader.id
            guard state == .receiving, let writer = writers[payloadID] else {
                throw TransferError.protocolViolation("file payload before acceptance or with unknown id")
            }
            guard payload.payloadHeader.totalSize == writer.expectedSize else {
                throw TransferError.protocolViolation("file payload size differs from introduction")
            }
            let body = payload.payloadChunk.body
            try await writer.append(body, at: payload.payloadChunk.offset)
            receivedBytes += Int64(body.count)
            reportProgress()
            if payload.payloadChunk.flags & 1 != 0 {
                let url = try await writer.finish()
                writers[payloadID] = nil
                emit(.receivedFile(transferID: id, url: url))
                try await completePayload(payloadID)
            }
        default:
            throw TransferError.protocolViolation("unsupported payload type \(payload.payloadHeader.type)")
        }
    }

    private func handleSharing(_ frame: SharingFrame, _ transport: SecureTransport) async throws {
        switch frame.v1.type {
        case .pairedKeyEncryption:
            guard state == .awaitingPairedKeyEncryption else {
                throw TransferError.protocolViolation("PAIRED_KEY_ENCRYPTION in state \(state)")
            }
            let pke = frame.v1.pairedKeyEncryption
            diagnostics.debug(tag, "peer paired key: signedData=\(pke.signedData.count) B secretIDHash=\(pke.secretIDHash.count) B "
                + "qr_code_handshake_data=\(pke.hasQrCodeHandshakeData ? "\(pke.qrCodeHandshakeData.count) B" : "none")")
            try await transport.send(SharingFrames.pairedKeyResult())
            enter(.awaitingPairedKeyResult, deadline: Limits.pairedKeyTimeout)
        case .pairedKeyResult:
            guard state == .awaitingPairedKeyResult else {
                throw TransferError.protocolViolation("PAIRED_KEY_RESULT in state \(state)")
            }
            enter(.awaitingIntroduction, deadline: Limits.introductionTimeout)
        case .introduction:
            guard state == .awaitingIntroduction else {
                throw TransferError.protocolViolation("INTRODUCTION in state \(state)")
            }
            try await handleIntroduction(frame.v1.introduction, transport)
        case .cancel:
            diagnostics.info(tag, "peer sent CANCEL in state \(state)")
            throw TransferError.cancelledByPeer
        default:
            diagnostics.debug(tag, "ignoring sharing frame \(frame.v1.type)")
        }
    }

    private func handleIntroduction(_ intro: Nearby_Sharing_Service_Proto_IntroductionFrame, _ transport: SecureTransport) async throws {
        let unsupported = !intro.wifiCredentialsMetadata.isEmpty || !intro.appMetadata.isEmpty || !intro.streamMetadata.isEmpty
        if unsupported || (intro.fileMetadata.isEmpty && intro.textMetadata.isEmpty) {
            diagnostics.info(tag, "unsupported introduction content")
            try? await transport.send(SharingFrames.response(.unsupportedAttachmentType))
            throw TransferError.unsupportedContent
        }
        guard intro.fileMetadata.count <= Limits.maxFiles, intro.textMetadata.count <= Limits.maxTexts else {
            try? await transport.send(SharingFrames.response(.reject))
            throw TransferError.protocolViolation("too many items in introduction")
        }

        var files: [FileOffer] = []
        var total: Int64 = 0
        for meta in intro.fileMetadata {
            guard meta.size >= 0, !outstanding.contains(meta.payloadID) else {
                throw TransferError.protocolViolation("invalid file entry in introduction")
            }
            let (sum, overflow) = total.addingReportingOverflow(meta.size)
            guard !overflow else { throw TransferError.protocolViolation("total size overflow") }
            total = sum
            let folder = FileNameSanitizer.sanitizeFolder(meta.hasParentFolder ? meta.parentFolder : nil)
            let offer = FileOffer(
                name: FileNameSanitizer.sanitizeComponent(meta.name),
                size: meta.size,
                mimeType: FileNameSanitizer.displayString(meta.mimeType, maxLength: 100),
                parentFolder: folder.isEmpty ? nil : folder.joined(separator: "/")
            )
            fileMetadata[meta.payloadID] = (offer, folder)
            outstanding.insert(meta.payloadID)
            files.append(offer)
        }
        var texts: [TextOffer] = []
        for meta in intro.textMetadata {
            guard meta.size >= 0, meta.size <= Int64(Limits.maxBytesPayload), !outstanding.contains(meta.payloadID) else {
                throw TransferError.protocolViolation("invalid text entry in introduction")
            }
            let kind: TextKind = switch meta.type {
            case .url: .url
            case .address: .address
            case .phoneNumber: .phoneNumber
            default: .text
            }
            let offer = TextOffer(title: FileNameSanitizer.displayString(meta.textTitle), kind: kind, size: meta.size)
            textMetadata[meta.payloadID] = offer
            outstanding.insert(meta.payloadID)
            texts.append(offer)
            total += meta.size
        }
        totalBytes = total
        diagnostics.info(tag, "introduction: \(files.count) files, \(texts.count) texts, \(total) bytes, "
            + "mime=\(Set(files.map(\.mimeType)).sorted()) folders=\(files.contains { $0.parentFolder != nil })")

        enter(.awaitingDecision, deadline: nil)
        let request = IncomingTransferRequest(id: id, device: device!, pin: pin, files: files, texts: texts)
        emit(.incomingRequest(request))
        let timeout = config.decisionTimeout
        decisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.decisionTimedOut()
        }
    }

    private func decisionTimedOut() async {
        guard state == .awaitingDecision, let transport else { return }
        diagnostics.info(tag, "accept prompt timed out")
        try? await transport.send(SharingFrames.response(.timedOut))
        await finish(with: .failed(transferID: id, error: .timedOut), lingerSeconds: 2)
    }

    private func completePayload(_ payloadID: Int64) async throws {
        outstanding.remove(payloadID)
        guard outstanding.isEmpty else { return }
        reportProgress(force: true)
        diagnostics.info(tag, "all payloads received")
        try? await transport?.send(OfflineFrames.disconnection())
        await finish(with: .completed(transferID: id), lingerSeconds: 0)
    }

    // MARK: Helpers

    private func enter(_ newState: State, deadline: TimeInterval?) {
        diagnostics.debug(tag, "state \(state) → \(newState)")
        state = newState
        stageDeadline = deadline.map { Date().addingTimeInterval($0) }
    }

    private func reportProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgress) >= 0.1 else { return }
        lastProgress = now
        emit(.progress(transferID: id, bytes: receivedBytes, totalBytes: totalBytes))
    }

    private func checkFreeSpace(at root: URL) throws {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let available, available - config.reservedSpace < totalBytes {
            diagnostics.info(tag, "not enough space: need \(totalBytes), have \(available)")
            throw TransferError.notEnoughSpace
        }
    }

    private func prepareWriters(root: URL) throws {
        for (payloadID, entry) in fileMetadata {
            let folder = try Destination.folder(root: root, components: entry.folder, created: &createdFolders)
            writers[payloadID] = try IncomingFileWriter(payloadID: payloadID, expectedSize: entry.offer.size,
                                                        folder: folder, name: entry.offer.name)
        }
    }

    private func startKeepAlive() {
        let interval = config.identity.options.keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.sendKeepAlive()
            }
        }
    }

    private func sendKeepAlive() async {
        guard state != .done, let transport else { return }
        try? await transport.send(OfflineFrames.keepAlive(ack: false))
    }

    private func fail(_ error: TransferError, notifyPeer: Bool) async {
        guard state != .done else { return }
        diagnostics.error(tag, "transfer failed in state \(state): \(error)")
        if notifyPeer, let transport {
            try? await transport.send(SharingFrames.cancel())
            try? await transport.send(OfflineFrames.disconnection())
        }
        for writer in writers.values { writer.discard() }
        writers.removeAll()
        // Remove folders we created that are still empty, deepest first.
        for folder in createdFolders.reversed() {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // Only report sessions that got far enough for the user to know about them.
        let visible = device != nil && [.awaitingDecision, .receiving].contains(state)
        await finish(with: visible ? .failed(transferID: id, error: error) : nil, lingerSeconds: 0)
    }

    private func finish(with event: TransferEvent?, lingerSeconds: TimeInterval) async {
        guard state != .done else { return }
        state = .done
        keepAliveTask?.cancel()
        decisionTask?.cancel()
        if let event { emit(event) }
        if lingerSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(lingerSeconds * 1_000_000_000)) }
        stream.close()
        diagnostics.info(tag, "session closed")
        onFinish(id)
    }
}
