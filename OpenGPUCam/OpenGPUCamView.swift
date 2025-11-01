//  ContentView.swift
//  OpenGPUCam
//  Created by Devin Sewell on 10/31/25.

import SwiftUI
import AVFoundation
import CoreImage
import Photos

struct OpenGPUCamView: View {
    @StateObject private var cam = CameraController()
    @State private var hueOffset: Float = -180
    @State private var contrast: Float = 3.0
    @State private var zoom: Float = 1
    @State private var saveMsg: String?

    var body: some View {
        ZStack {
            CameraPreview(controller: cam)
                .edgesIgnoringSafeArea(.all)
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Text(String(format: "Contrast ×%.2f", contrast)).foregroundColor(.white).font(.caption)
                    Slider(value: Binding(
                        get: { Double(contrast) },
                        set: { v in contrast = Float(v); cam.contrast = contrast }
                    ), in: 0.1...6.0)
                    .tint(.orange)
                    Text(String(format: "Zoom ×%.2f", zoom)).foregroundColor(.white).font(.caption)
                    Slider(value: Binding(
                        get: { Float(zoom) },
                        set: { v in zoom = Float(v); cam.setZoom(factor: zoom) }
                    ), in: 1...cam.maxZoom)
                    .tint(.gray)
                    
                    Text("Hue Offset \(Int(hueOffset))°").foregroundColor(.white).font(.caption)
                    Slider(value: Binding(
                        get: { Double(hueOffset) },
                        set: { v in hueOffset = Float(v); cam.hueOffset = hueOffset }
                    ), in: -180...180)
                    // Fancy way to set the Hue Offset track color to approx. hue
                    .tint(Color(hue: Double((hueOffset.truncatingRemainder(dividingBy: 360)) / 360), saturation: 1, brightness: 1))
                    
                }
                .padding(.horizontal, 40)
                HStack(spacing: 40) {
                    Button { cam.capturePhoto { saveMsg = $0 } } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 28))
                            .padding()
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    Button { cam.toggleRecord { saveMsg = $0 } } label: {
                        Text("●")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(cam.recording ? .white : .red)
                            .padding()
                            .background(cam.recording ? Color.red : Color.white)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 30)
            }
            if let msg = saveMsg {
                VStack {
                    Text(msg)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .transition(.opacity)
                        .padding(.top, 10)
                    Spacer()
                }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saveMsg = nil } }
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .background(Color.black)
    }
}

// MARK: - Live Preview UIView
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController
    func makeUIView(context: Context) -> UIView {
        controller.previewView
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - CameraController
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let ctx = CIContext()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private(set) var device: AVCaptureDevice?
    let previewView = PreviewView()
    var hueOffset: Float = -180
    var contrast: Float = 3.0
    var maxZoom: Float = 6
    @Published var recording = false

    override init() {
        super.init()
        session.sessionPreset = .high

        guard let dev = AVCaptureDevice.default(for: .video),
              let inp = try? AVCaptureDeviceInput(device: dev)
        else { return }

        device = dev
        if session.canAddInput(inp) { session.addInput(inp) }

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "vidq"))
        if session.canAddOutput(out) { session.addOutput(out) }

        previewView.videoLayer.session = session
        updateOrientation()
        maxZoom = Float(min(dev.activeFormat.videoMaxZoomFactor, 6))

        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateOrientation() }
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }

    private func updateOrientation() {
        let o = UIDevice.current.orientation
        guard let preview = previewView.videoLayer.connection else { return }

        // Update preview orientation
        if preview.isVideoOrientationSupported {
            switch o {
            case .landscapeLeft:
                preview.videoOrientation = .landscapeRight
            case .landscapeRight:
                preview.videoOrientation = .landscapeLeft
            case .portrait:
                preview.videoOrientation = .portrait
            case .portraitUpsideDown:
                preview.videoOrientation = .portraitUpsideDown
            default:
                break
            }
        }

        // Update output video orientation
        if let conn = session.outputs.first?.connection(with: .video),
           conn.isVideoOrientationSupported {
            conn.videoOrientation = preview.videoOrientation
        }

        // Update preview bounds
        DispatchQueue.main.async {
            self.previewView.videoLayer.frame = self.previewView.bounds
        }
    }

    func setZoom(factor: Float) {
        guard let dev = device else { return }
        let safeZoom = min(max(factor, 1), maxZoom)
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = CGFloat(safeZoom)
            dev.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            dev.focusMode = .continuousAutoFocus
            dev.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            dev.exposureMode = .continuousAutoExposure
            dev.unlockForConfiguration()
        } catch { print("zoom error:", error) }
    }

    func toggleRecord(_ callback: @escaping (String)->Void) {
        guard previewView.currentFrame != nil else { callback("No camera available."); return }
        if recording {
            recording = false
            input?.markAsFinished()
            writer?.finishWriting {
                if let url = self.writer?.outputURL {
                    self.saveVideo(url) { ok in callback(ok ? "Video saved." : "Failed to save video.") }
                }
                self.writer = nil
            }
        } else {
            recording = true
            writer = nil
            startTime = nil
        }
    }

    func capturePhoto(_ callback: @escaping (String)->Void) {
        guard let frame = previewView.currentFrame else { callback("No camera available."); return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: frame)
        }) { ok, _ in DispatchQueue.main.async { callback(ok ? "Photo saved." : "Failed to save photo.") } }
    }

    // MARK: - Frame Processing
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ci = CIImage(cvPixelBuffer: px)
        let filtered = applyFX(ci)
        previewView.updateFrame(filtered, ctx: ctx)

        // Setup recording
        if recording && writer == nil {
            let url = outURL()
            writer = try? AVAssetWriter(outputURL: url, fileType: .mp4)
            let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h
            ]
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input!.expectsMediaDataInRealTime = true
            writer!.add(input!)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: w,
                    kCVPixelBufferHeightKey as String: h
                ])
            writer!.startWriting()
            writer!.startSession(atSourceTime: ts)
            startTime = ts
        }
        if recording, // Process pixel buffer data and add it to the video stream.
           let writer = writer, writer.status == .writing,
           let input = input, input.isReadyForMoreMediaData,
           let adaptor = adaptor, let pool = adaptor.pixelBufferPool {
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            if let pb = pbOut {
                ctx.render(filtered, to: pb)
                adaptor.append(pb, withPresentationTime: ts)
            }
        }
    }

    private func applyFX(_ img: CIImage) -> CIImage {
        let hue = CIFilter(name: "CIHueAdjust")!
        hue.setValue(img, forKey: kCIInputImageKey)
        hue.setValue(hueOffset * (.pi / 180), forKey: kCIInputAngleKey)
        let outHue = hue.outputImage ?? img

        let contrastF = CIFilter(name: "CIColorControls")!
        contrastF.setValue(outHue, forKey: kCIInputImageKey)
        contrastF.setValue(contrast, forKey: kCIInputContrastKey)
        return contrastF.outputImage ?? outHue
    }

    private func outURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        return dir.appendingPathComponent("clip_\(df.string(from: Date())).mp4")
    }

    private func saveVideo(_ url: URL, completion: @escaping (Bool)->Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { ok, _ in DispatchQueue.main.async { completion(ok) } }
    }
}

// MARK: - PreviewView (UIView)
class PreviewView: UIView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    private let overlay = UIImageView()
    private var ciContext = CIContext()
    private(set) var currentFrame: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        videoLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(videoLayer)
        overlay.contentMode = .scaleAspectFill
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateFrame(_ ci: CIImage, ctx: CIContext) {
        if let cg = ctx.createCGImage(ci, from: ci.extent) {
            let ui = UIImage(cgImage: cg)
            currentFrame = ui
            DispatchQueue.main.async { self.overlay.image = ui }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
    }
}
