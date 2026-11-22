import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Minimal H.264 Annex-B stream decoder backed by VideoToolbox.
/// The scrcpy raw video stream is Annex-B without frame metadata, so we
/// split NAL units ourselves and wrap each access unit into a CMSampleBuffer.
final class H264StreamDecoder {
    private let queue = DispatchQueue(label: "com.androidconnection.h264", qos: .userInteractive)
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var buffer = Data()
    private var frameIndex: Int64 = 0
    private var parameterKey = ""
    private var reportedError = false

    var onFrame: ((CVPixelBuffer, CGSize) -> Void)?
    var onError: ((String) -> Void)?

    func reset() {
        queue.sync {
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
            session = nil
            formatDescription = nil
            sps = nil
            pps = nil
            buffer.removeAll(keepingCapacity: false)
            frameIndex = 0
            parameterKey = ""
            reportedError = false
        }
    }

    func append(_ data: Data) {
        queue.async { [weak self] in
            self?.consume(data)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        let bytes = [UInt8](buffer)
        guard bytes.count > 8 else { return }

        var starts: [Int] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index)
                index += 3
            } else {
                index += 1
            }
        }
        guard starts.count >= 2 else {
            if buffer.count > 8 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: true)
            }
            return
        }

        for position in 0..<(starts.count - 1) {
            let payloadStart = starts[position] + 3
            var payloadEnd = starts[position + 1]
            if payloadEnd > payloadStart, bytes[payloadEnd - 1] == 0 {
                payloadEnd -= 1
            }
            if payloadEnd > payloadStart {
                handle(nal: Data(bytes[payloadStart..<payloadEnd]))
            }
        }

        let lastStart = starts[starts.count - 1]
        var keepFrom = lastStart
        if lastStart >= 3,
           bytes[lastStart - 1] == 0,
           bytes[lastStart - 2] == 0,
           bytes[lastStart - 3] == 0 {
            keepFrom = lastStart - 1
        }
        buffer = Data(bytes[keepFrom...])
    }

    private func handle(nal: Data) {
        guard let first = nal.first else { return }
        let type = first & 0x1f
        switch type {
        case 7:
            sps = nal
            rebuildIfNeeded()
        case 8:
            pps = nal
            rebuildIfNeeded()
        case 5:
            decode(nal, keyframe: true)
        case 1:
            decode(nal, keyframe: false)
        default:
            break
        }
    }

    private func rebuildIfNeeded() {
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty else { return }
        let key = "\(sps.count):\(sps.hashValue):\(pps.count):\(pps.hashValue)"
        guard key != parameterKey else { return }
        parameterKey = key

        var format: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
                    sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }

        guard status == noErr, let format else {
            report("无法读取 H.264 参数集（\(status)）")
            return
        }

        formatDescription = format
        createSession(format)
    }

    private func createSession(_ format: CMVideoFormatDescription) {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        if status == noErr, let newSession {
            session = newSession
        } else {
            report("无法创建视频解码器（\(status)）")
        }
    }

    private func decode(_ nal: Data, keyframe: Bool) {
        guard let formatDescription, let session else { return }

        var payload = Data()
        var units: [Data] = []
        if keyframe {
            if let sps { units.append(sps) }
            if let pps { units.append(pps) }
        }
        units.append(nal)

        payload.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(unit)
        }

        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else { return }

        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var size = payload.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 60),
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return }
        frameIndex += 1

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            let size = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
            self?.onFrame?(imageBuffer, size)
        }
        if decodeStatus != noErr {
            report("视频解码失败（\(decodeStatus)）")
        }
    }

    private func report(_ message: String) {
        guard !reportedError else { return }
        reportedError = true
        onError?(message)
    }
}
