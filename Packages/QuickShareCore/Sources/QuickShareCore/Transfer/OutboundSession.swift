import Foundation
import SwiftProtobuf

/// One outgoing transfer (we are the sender / client). See PROTOCOL_NOTES §4–§8.
actor OutboundSession {
    enum State: Equatable {
        case connecting
        case awaitingPairedKeyEncryption
        case awaitingPairedKeyResult
        case awaitingResponse
        case sending
        case done
    }

    nonisolated let id: UUID
    private let makeStream: @Sendable () async throws -> ByteStream
    private let items: [SendItem]
    private let device: RemoteDevice
    private let identity: LocalIdentity
    private let qrSession: QRCodeSession?
    private let diagnostics: Diagnostics
    private let emit: @Sendable (TransferEvent) -> Void
    private let tag: String
    /// How long to wait for the receiver to accept (Google's sender waits 60 s; the user may be slower).
    private let responseTimeout: TimeInterval

    private(set) var state: State = .connecting
    private var stageDeadline: Date?
    private var stream: ByteStream?
    private var transport: SecureTransport?
    private var assembler = BytesPayloadAssembler()
    private var files: [PreparedFile] = []
    private var texts: [PreparedText] = []
    private var totalBytes: Int64 = 0
    private var sentBytes: Int64 = 0
    private var lastProgress = Date.distantPast
    /// Set just before the final frame is enqueued. A receiver that has everything disconnects,
    /// and may do so before our send completion runs, so disconnects after this point are success.
    private var allQueued = false
    private var userCancelled = false
    private var keepAliveTask: Task<Void, Never>?
    /// The TCP connect in progress, so cancel can interrupt it instead of waiting for its timeout.
    private var connectTask: Task<ByteStream, Error>?

    init(id: UUID = UUID(), makeStream: @escaping @Sendable () async throws -> ByteStream, items: [SendItem],
         device: RemoteDevice, identity: LocalIdentity, qrSession: QRCodeSession?, diagnostics: Diagnostics,
         responseTimeout: TimeInterval = 120, emit: @escaping @Sendable (TransferEvent) -> Void) {
        self.id = id
        self.makeStream = makeStream
        self.items = items
        self.device = device
        self.identity = identity
        self.qrSession = qrSession
        self.diagnostics = diagnostics
        self.responseTimeout = responseTimeout
        self.emit = emit
        tag = "out-\(id.uuidString.prefix(4))"
    }

    func run() async {
        do {
            let prepared = try OutgoingItems.prepare(items)
            files = prepared.files
            texts = prepared.texts
            totalBytes = files.reduce(0) { $0 + $1.size } + texts.reduce(0) { $0 + Int64($1.data.count) }
            if prepared.skippedEmpty > 0 { diagnostics.info(tag, "skipping \(prepared.skippedEmpty) empty files") }
            guard !files.isEmpty || !texts.isEmpty else { throw TransferError.unsupportedContent }

            if userCancelled { throw TransferError.cancelledByUser }
            let connect = Task { try await makeStream() }
            connectTask = connect
            let stream = try await connect.value
            connectTask = nil
            self.stream = stream
            if userCancelled {
                stream.close()
                throw TransferError.cancelledByUser
            }
            let ukey = try await Handshake.runClient(stream: stream, endpointID: ServiceName.randomEndpointID(),
                                                     identity: identity, diagnostics: diagnostics, tag: tag)
            let transport = SecureTransport(stream: stream, keys: SecureChannelKeys(nextSecret: ukey.nextSecret, role: .client),
                                            diagnostics: diagnostics, tag: tag)
            self.transport = transport
            let pin = ukey.pin
            emit(.awaitingAcceptance(transferID: id, device: device, pin: pin))
            startKeepAlive()

            let qrData = try qrSession?.handshakeSignature(authString: ukey.authString)
            try await transport.send(SharingFrames.pairedKeyEncryption(qrCodeHandshakeData: qrData))
            enter(.awaitingPairedKeyEncryption, deadline: Limits.pairedKeyTimeout)

            // Negotiate until the receiver accepts.
            while state != .sending {
                let frame = try await receiveNext(transport)
                try await handleNegotiation(frame, transport)
            }
            try await transferPayloads(transport, stream)
            await finish(with: .completed(transferID: id))
        } catch {
            let mapped = userCancelled ? .cancelledByUser : transferError(from: error)
            await fail(mapped)
        }
    }

    func cancel() async {
        guard state != .done, !userCancelled else { return }
        userCancelled = true
        diagnostics.info(tag, "user cancelled in state \(state)")
        connectTask?.cancel()
        if let transport {
            try? await transport.send(SharingFrames.cancel())
            try? await transport.send(OfflineFrames.disconnection())
        }
        stream?.close()
    }

    // MARK: Negotiation

    private func handleNegotiation(_ frame: OfflineFrame, _ transport: SecureTransport) async throws {
        if let sharing = try await handleCommon(frame, transport) {
            switch sharing.v1.type {
            case .pairedKeyEncryption:
                guard state == .awaitingPairedKeyEncryption else {
                    throw TransferError.protocolViolation("PAIRED_KEY_ENCRYPTION in state \(state)")
                }
                try await transport.send(SharingFrames.pairedKeyResult())
                enter(.awaitingPairedKeyResult, deadline: Limits.pairedKeyTimeout)
            case .pairedKeyResult:
                guard state == .awaitingPairedKeyResult else {
                    throw TransferError.protocolViolation("PAIRED_KEY_RESULT in state \(state)")
                }
                try await transport.send(SharingFrames.introduction(files: files.map(\.metadata), texts: texts.map(\.metadata)))
                diagnostics.info(tag, "sent introduction: \(files.count) files, \(texts.count) texts, \(totalBytes) bytes")
                enter(.awaitingResponse, deadline: responseTimeout)
            case .response:
                guard state == .awaitingResponse else {
                    throw TransferError.protocolViolation("RESPONSE in state \(state)")
                }
                let status = sharing.v1.connectionResponse.status
                diagnostics.info(tag, "receiver responded \(status)")
                switch status {
                case .accept: enter(.sending, deadline: nil)
                case .notEnoughSpace: throw TransferError.notEnoughSpace
                case .unsupportedAttachmentType: throw TransferError.unsupportedContent
                case .timedOut: throw TransferError.timedOut
                default: throw TransferError.declined
                }
            case .cancel:
                throw TransferError.cancelledByPeer
            default:
                diagnostics.debug(tag, "ignoring sharing frame \(sharing.v1.type)")
            }
        }
    }

    /// Handles frames valid in any state. Returns a completed sharing frame, if one arrived.
    private func handleCommon(_ frame: OfflineFrame, _ transport: SecureTransport) async throws -> SharingFrame? {
        guard frame.hasV1 else { return nil }
        switch frame.v1.type {
        case .keepAlive:
            if !frame.v1.keepAlive.ack { try await transport.send(OfflineFrames.keepAlive(ack: true)) }
        case .disconnection:
            diagnostics.info(tag, "peer sent DISCONNECTION in state \(state)")
            if allQueued { throw TransportError.closed }
            throw state == .awaitingResponse ? TransferError.declined : TransferError.connectionLost
        case .payloadTransfer:
            let payload = frame.v1.payloadTransfer
            if payload.packetType == .control {
                if payload.controlMessage.event == .payloadCanceled || payload.controlMessage.event == .payloadError {
                    throw TransferError.cancelledByPeer
                }
                return nil
            }
            guard payload.payloadHeader.type == .bytes else {
                throw TransferError.protocolViolation("receiver sent a \(payload.payloadHeader.type) payload")
            }
            guard let (_, data) = try assembler.add(payload) else { return nil }
            guard let sharing = try? SharingFrame(serializedBytes: data), sharing.hasV1 else {
                throw TransferError.protocolViolation("undecodable sharing frame")
            }
            diagnostics.debug(tag, "← sharing \(sharing.logDescription)")
            return sharing
        case .bandwidthUpgradeNegotiation:
            let upgrade = frame.v1.bandwidthUpgradeNegotiation
            if upgrade.eventType == .upgradePathAvailable, identity.options.rejectBandwidthUpgrade {
                diagnostics.info(tag, "declining bandwidth upgrade to \(upgrade.upgradePathInfo.medium)")
                try await transport.send(OfflineFrames.upgradeFailure(medium: upgrade.upgradePathInfo.medium))
            }
        default:
            diagnostics.debug(tag, "ignoring \(frame.v1.type)")
        }
        return nil
    }

    // MARK: Payload transfer

    private func transferPayloads(_ transport: SecureTransport, _ stream: ByteStream) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readDuringTransfer(transport, stream) }
            group.addTask { try await self.sendAll(transport, stream) }
            // The first task to finish decides; the other is stopped.
            try await group.next()
            group.cancelAll()
            stream.close()
            try await group.waitForAll()
        }
    }

    /// Answers keep-alives and watches for cancel or disconnection while files are being sent.
    private func readDuringTransfer(_ transport: SecureTransport, _ stream: ByteStream) async throws {
        do {
            while true {
                let frame = try await receiveNext(transport)
                if let sharing = try await handleCommon(frame, transport), sharing.v1.type == .cancel {
                    throw TransferError.cancelledByPeer
                }
            }
        } catch {
            stream.close()
            if allQueued, !userCancelled, error is TransportError { return }
            throw error
        }
    }

    private func sendAll(_ transport: SecureTransport, _ stream: ByteStream) async throws {
        do {
            for (index, file) in files.enumerated() {
                try await sendFile(file, transport, isFinalItem: texts.isEmpty && index == files.count - 1)
            }
            for (index, text) in texts.enumerated() {
                try Task.checkCancellation()
                try await transport.send(OfflineFrames.payload(id: text.payloadID, type: .bytes, totalSize: Int64(text.data.count),
                                                               offset: 0, body: text.data, last: false))
                if index == texts.count - 1 { allQueued = true }
                try await transport.send(OfflineFrames.payload(id: text.payloadID, type: .bytes, totalSize: Int64(text.data.count),
                                                               offset: Int64(text.data.count), body: Data(), last: true))
                sentBytes += Int64(text.data.count)
            }
            reportProgress(force: true)
            diagnostics.info(tag, "all payloads sent; waiting for receiver to disconnect")
            // The receiver is expected to disconnect once it has everything (PROTOCOL_NOTES §7.4).
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled {
                diagnostics.info(tag, "receiver did not disconnect; closing")
                try? await transport.send(OfflineFrames.disconnection())
            }
        } catch {
            stream.close()
            throw error
        }
    }

    private func sendFile(_ file: PreparedFile, _ transport: SecureTransport, isFinalItem: Bool) async throws {
        let reader: FileChunkReader
        do {
            reader = try FileChunkReader(url: file.url)
        } catch {
            throw TransferError.fileAccess(error.localizedDescription)
        }
        defer { reader.close() }
        let chunkSize = max(16 * 1024, min(identity.options.chunkSize, 4 * 1024 * 1024))
        let size = file.size
        let trailingEmpty = identity.options.sendTrailingEmptyChunk
        var offset: Int64 = 0

        func header(_ body: Data, last: Bool) -> OfflineFrame {
            var frame = OfflineFrames.payload(id: file.payloadID, type: .file, totalSize: size, offset: offset, body: body, last: last)
            frame.v1.payloadTransfer.payloadHeader.fileName = file.metadata.name
            if file.metadata.hasParentFolder { frame.v1.payloadTransfer.payloadHeader.parentFolder = file.metadata.parentFolder }
            return frame
        }

        var current = try await reader.read(upTo: min(chunkSize, Int(size)))
        while !current.isEmpty {
            try Task.checkCancellation()
            let remainingAfter = size - offset - Int64(current.count)
            guard remainingAfter >= 0 else { throw TransferError.fileAccess("file grew while sending") }
            // Read the next chunk from disk while this one is encrypted and sent.
            async let next = remainingAfter > 0 ? reader.read(upTo: min(chunkSize, Int(remainingAfter))) : Data()
            let isLast = remainingAfter == 0 && !trailingEmpty
            if isLast, isFinalItem { allQueued = true }
            try await transport.send(header(current, last: isLast))
            offset += Int64(current.count)
            sentBytes += Int64(current.count)
            reportProgress()
            current = try await next
        }
        guard offset == size else { throw TransferError.fileAccess("file shrank while sending") }
        if trailingEmpty {
            if isFinalItem { allQueued = true }
            try await transport.send(header(Data(), last: true))
        }
    }

    // MARK: Helpers

    private func receiveNext(_ transport: SecureTransport) async throws -> OfflineFrame {
        var timeout = identity.options.idleTimeout
        var stage = "frame"
        if let stageDeadline {
            let remaining = stageDeadline.timeIntervalSinceNow
            if remaining <= 0 { throw TransportError.timedOut("\(state)") }
            if remaining < timeout { timeout = remaining; stage = "\(state)" }
        }
        let stream = self.stream
        return try await withTimeout(timeout, stage: stage, onTimeout: { stream?.close() }) {
            try await transport.receive()
        }
    }

    private func enter(_ newState: State, deadline: TimeInterval?) {
        diagnostics.debug(tag, "state \(state) → \(newState)")
        state = newState
        stageDeadline = deadline.map { Date().addingTimeInterval($0) }
    }

    private func reportProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgress) >= 0.1 else { return }
        lastProgress = now
        emit(.progress(transferID: id, bytes: sentBytes, totalBytes: totalBytes))
    }

    private func startKeepAlive() {
        let interval = identity.options.keepAliveInterval
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

    private func fail(_ error: TransferError) async {
        guard state != .done else { return }
        diagnostics.error(tag, "transfer failed in state \(state): \(error.logDescription)")
        await finish(with: .failed(transferID: id, error: error))
    }

    private func finish(with event: TransferEvent) async {
        guard state != .done else { return }
        state = .done
        keepAliveTask?.cancel()
        stream?.close()
        emit(event)
        diagnostics.info(tag, "session closed")
    }
}
