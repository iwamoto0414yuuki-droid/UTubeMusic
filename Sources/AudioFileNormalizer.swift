import AVFoundation

/// Remux compressed AAC packets into a regular M4A. DASH movie duration is not
/// reliable on Apple players; neither renaming the file nor changing Song.duration fixes it.
enum AudioFileNormalizer {
    static func normalize(source: URL, destination: URL, expectedDuration: Double? = nil) async throws -> Double {
        let work = Task.detached(priority: .userInitiated) {
            try await remux(source: source, destination: destination, expectedDuration: expectedDuration)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private static func remux(source: URL, destination: URL, expectedDuration: Double?) async throws -> Double {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw AppFailure("音声の修復先を作成できません。元の曲は保持しています。")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, video.isEmpty, let track = tracks.first else {
            throw AppFailure("保存したデータを音楽として確認できません。")
        }
        let reader = try AVAssetReader(asset: asset)
        // nil copies original AAC, without decoding/re-encoding or silence detection.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AppFailure("音声データを読み込めません。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppFailure("音声データを読み込めません。") }
        defer { reader.cancelReading() }
        guard let first = output.copyNextSampleBuffer(),
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw reader.error ?? AppFailure("音声データがありません。")
        }
        let origin = CMSampleBufferGetPresentationTimeStamp(first)
        guard origin.isNumeric else { throw AppFailure("音声の開始時刻を確認できません。") }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AppFailure("音声をM4Aとして保存できません。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppFailure("音声を保存できません。") }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        // Let AVAssetWriter rebase the original timestamps. Compressed AAC buffers
        // can carry packet timing without an explicit per-sample timing array.
        writer.startSession(atSourceTime: origin)
        var next: CMSampleBuffer? = first
        var packetEnd = CMTime.zero
        while let sample = next {
            try Task.checkCancellation()
            let start = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), origin)
            let duration = CMSampleBufferGetDuration(sample)
            guard start.isNumeric, duration.isNumeric, duration.seconds > 0,
                  start.seconds >= 0, start.seconds <= packetEnd.seconds + 0.1 else {
                throw AppFailure("音声の時間情報が不正です。元の曲は保持しています。")
            }
            let end = CMTimeAdd(start, duration)
            guard end.seconds > packetEnd.seconds else { throw AppFailure("音声の時間情報が重複しています。") }
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? AppFailure("音声の保存処理が停止しました。再試行してください。")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard input.append(sample) else { throw writer.error ?? AppFailure("音声の保存に失敗しました。") }
            packetEnd = end
            next = output.copyNextSampleBuffer()
        }
        guard reader.status == .completed else { throw reader.error ?? AppFailure("音声を最後まで読み込めませんでした。") }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(origin, packetEnd))
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? AppFailure("音声の保存を完了できませんでした。") }
        let result = AVURLAsset(url: destination, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await result.load(.duration).seconds
        let playable = try await result.load(.isPlayable)
        let audioFile = try AVAudioFile(forReading: destination)
        let decodedDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard playable, duration.isFinite, duration > 0,
              decodedDuration.isFinite, decodedDuration > 0,
              abs(duration - packetEnd.seconds) <= 0.15,
              abs(duration - decodedDuration) <= 0.15 else {
            throw AppFailure("保存した音声の長さが一致しません。曲は登録されていません。")
        }
        if let expected = expectedDuration, expected.isFinite, expected > 0,
           abs(duration - expected) > max(2, expected * 0.02) {
            throw AppFailure("取得元の曲と音声の長さが一致しません。再試行してください。")
        }
        completed = true
        return duration
    }

}
