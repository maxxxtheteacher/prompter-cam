import AVFoundation
import Photos
import SwiftUI

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "promptercam.session")
    private var configured = false
    private var videoDevice: AVCaptureDevice?

    @Published var isRecording = false
    @Published var activeDescription = ""
    @Published var ready = false
    @Published var orientation: AVCaptureVideoOrientation = .portrait

    private static func stored<T>(_ key: String, _ fallback: T) -> T {
        (UserDefaults.standard.object(forKey: key) as? T) ?? fallback
    }
    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // Настройки (сохраняются между запусками)
    @Published var mirror: Bool = CameraManager.stored("mirrorPreview", false) {
        didSet { save("mirrorPreview", mirror) }
    }
    @Published var resolution: Int = CameraManager.stored("res", 2160) {
        didSet { save("res", resolution); applyFormat() }
    }
    @Published var fps: Int = CameraManager.stored("fps", 30) {
        didSet { save("fps", fps); applyFormat() }
    }
    @Published var hdr: Bool = CameraManager.stored("hdr", true) {
        didSet { save("hdr", hdr); applyFormat() }
    }
    @Published var bitrate: Int = CameraManager.stored("bitrate", 100) {
        didSet { save("bitrate", bitrate) }
    }
    @Published var stabilization: Bool = CameraManager.stored("stabilization", false) {
        didSet { save("stabilization", stabilization) }
    }
    @Published var exposureBias: Double = CameraManager.stored("ev", 0.7) {
        didSet { save("ev", exposureBias); applyLive() }
    }
    @Published var zoom: Double = CameraManager.stored("zoom", 1.0) {
        didSet { save("zoom", zoom); applyLive() }
    }

    // MARK: - Запуск

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.activeDescription = "Нет доступа к камере" }
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
        videoDevice = device

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        if session.canAddInput(videoInput) { session.addInput(videoInput) }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        session.beginConfiguration()
        configureFormat(device)
        session.commitConfiguration()

        configured = true
        DispatchQueue.main.async { self.ready = true }
    }

    // MARK: - Формат, цвет, экспозиция

    /// Вызывать только на `queue`.
    private func configureFormat(_ device: AVCaptureDevice) {
        let targetWidth: Int32 = resolution >= 2160 ? 3840 : 1920
        let wantFPS = Double(fps)

        var best: AVCaptureDevice.Format?
        var bestScore = -1
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width <= targetWidth else { continue }
            let okFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= wantFPS && $0.maxFrameRate >= wantFPS
            }
            guard okFPS else { continue }
            let isHLG = format.supportedColorSpaces.contains(.HLG_BT2020)
            var score = Int(dims.width)
            if hdr == isHLG { score += 100_000 }
            if !format.isVideoBinned { score += 10_000 }
            if score > bestScore {
                best = format
                bestScore = score
            }
        }
        guard let format = best, (try? device.lockForConfiguration()) != nil else { return }

        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        let useHLG = hdr && format.supportedColorSpaces.contains(.HLG_BT2020)
        if useHLG {
            device.activeColorSpace = .HLG_BT2020   // 10-бит HDR, как в стандартной камере
        } else {
            if format.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = hdr
            }
        }

        // Экспозиция по лицу, как в стандартной камере
        if #available(iOS 15.4, *) {
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            device.isFaceDrivenAutoExposureEnabled = true
        }
        applyLiveLocked(device)
        device.unlockForConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let text = "\(dims.width)×\(dims.height) \(fps)fps " + (useHLG ? "HLG" : "SDR")
        DispatchQueue.main.async { self.activeDescription = text }
    }

    /// Яркость и зум. Вызывать при залоченной конфигурации устройства.
    private func applyLiveLocked(_ device: AVCaptureDevice) {
        let bias = max(device.minExposureTargetBias, min(Float(exposureBias), device.maxExposureTargetBias))
        device.setExposureTargetBias(bias, completionHandler: nil)
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 4.0)
        device.videoZoomFactor = max(1.0, min(CGFloat(zoom), maxZoom))
    }

    func applyFormat() {
        queue.async {
            guard self.configured, let device = self.videoDevice, !self.movieOutput.isRecording else { return }
            self.session.beginConfiguration()
            self.configureFormat(device)
            self.session.commitConfiguration()
        }
    }

    func applyLive() {
        queue.async {
            guard self.configured, let device = self.videoDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            self.applyLiveLocked(device)
            device.unlockForConfiguration()
        }
    }

    func focus(at devicePoint: CGPoint) {
        queue.async {
            guard let device = self.videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Ориентация

    func updateOrientation() {
        switch UIDevice.current.orientation {
        case .portrait: orientation = .portrait
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        default: break
        }
    }

    // MARK: - Запись

    func toggleRecording() {
        queue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard let conn = self.movieOutput.connection(with: .video) else { return }
            if self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                self.movieOutput.setOutputSettings([
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: self.bitrate * 1_000_000]
                ], for: conn)
            }
            if conn.isVideoOrientationSupported { conn.videoOrientation = self.orientation }
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = self.stabilization ? .auto : .off
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = self.mirror
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
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
                DispatchQueue.main.async {
                    self.activeDescription = success ? "Сохранено в Фото ✓" : "Ошибка сохранения"
                }
            }
        }
    }
}

// MARK: - Превью камеры

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let ready: Bool
    let mirror: Bool
    let orientation: AVCaptureVideoOrientation
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
        if let conn = uiView.previewLayer.connection {
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = mirror
            }
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = orientation
            }
        }
    }
}
