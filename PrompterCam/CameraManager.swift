import AVFoundation
import Photos
import SwiftUI

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "promptercam.session")
    private var configured = false

    @Published var isRecording = false
    @Published var info = ""
    @Published var ready = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.info = "Нет доступа к камере" }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async {
                    if !self.configured { self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if session.canAddInput(videoInput) { session.addInput(videoInput) }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        // Формат: максимум разрешения до 4K при 30 fps, 8-бит SDR (без HDR/HLG), без binning
        var best: AVCaptureDevice.Format?
        var bestScore = -1
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width <= 3840 else { continue }
            let supports30 = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
            guard supports30 else { continue }
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is8bit = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let score = Int(dims.width) + (is8bit ? 100_000 : 0) + (format.isVideoBinned ? 0 : 10_000)
            if score > bestScore {
                best = format
                bestScore = score
            }
        }
        if let best = best, (try? device.lockForConfiguration()) != nil {
            device.activeFormat = best
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            if best.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            device.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            DispatchQueue.main.async { self.info = "\(d.width)×\(d.height) 30fps HEVC 100 Mbps" }
        }

        session.commitConfiguration()

        // Настройки соединения для записи (после commit, когда connection уже существует)
        if let conn = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 100_000_000]
                ], for: conn)
            }
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false   // запись не зеркальная
            }
        }

        configured = true
        DispatchQueue.main.async { self.ready = true }
    }

    func toggleRecording() {
        queue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, _ in
                try? FileManager.default.removeItem(at: outputFileURL)
                DispatchQueue.main.async { self.info = success ? "Сохранено в Фото ✓" : "Ошибка сохранения" }
            }
        }
    }
}

// MARK: - Превью камеры

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let ready: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Превью без зеркала, как в Blackmagic Cam
        if let conn = uiView.previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
        }
    }
}
