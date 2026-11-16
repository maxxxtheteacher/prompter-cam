import SwiftUI

final class PrompterModel: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var running = false
    var speed: Double = 40
    private var timer: Timer?
    private var last = Date()

    func start() {
        guard !running else { return }
        running = true
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date()
            let dt = now.timeIntervalSince(self.last)
            self.last = now
            self.offset += CGFloat(self.speed * dt)
        }
    }

    func pause() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        offset = 0
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var prompter = PrompterModel()

    @AppStorage("script") private var script = "Вставь сюда свой текст: нажми на карандаш внизу."
    @AppStorage("fontSize") private var fontSize = 34.0
    @AppStorage("speed") private var speed = 40.0
    @AppStorage("mirrorText") private var mirrorText = false
    @State private var showEditor = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: camera.session, ready: camera.ready)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    prompterBox(height: geo.size.height * 0.36)
                    Spacer()
                    controls
                }
            }
        }
        .onAppear {
            camera.start()
            prompter.speed = speed
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: speed) { prompter.speed = $0 }
        .sheet(isPresented: $showEditor) { editor }
    }

    private func prompterBox(height: CGFloat) -> some View {
        Text(script)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .offset(y: -prompter.offset)
            .frame(height: height, alignment: .top)
            .clipped()
            .background(Color.black.opacity(0.45))
            .scaleEffect(x: mirrorText ? -1 : 1, y: 1)
            .padding(.top, 50)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !camera.info.isEmpty {
                Text(camera.info).font(.caption).foregroundColor(.white.opacity(0.8))
            }
            HStack {
                Text("Скорость").font(.caption)
                Slider(value: $speed, in: 10...150)
            }
            HStack {
                Text("Шрифт").font(.caption)
                Slider(value: $fontSize, in: 20...64)
            }
            HStack(spacing: 28) {
                Button { showEditor = true } label: { icon("pencil") }
                Button { prompter.reset() } label: { icon("backward.end.fill") }
                Button {
                    prompter.running ? prompter.pause() : prompter.start()
                } label: { icon(prompter.running ? "pause.fill" : "play.fill") }

                Button {
                    camera.toggleRecording()
                    if camera.isRecording { prompter.pause() } else { prompter.start() }
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 70, height: 70)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                            .fill(Color.red)
                            .frame(width: camera.isRecording ? 28 : 56, height: camera.isRecording ? 28 : 56)
                    }
                }

                Button { mirrorText.toggle() } label: { icon("arrow.left.and.right.righttriangle.left.righttriangle.right") }
            }
        }
        .padding()
        .background(Color.black.opacity(0.55))
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
    }

    private var editor: some View {
        NavigationView {
            TextEditor(text: $script)
                .font(.system(size: 18))
                .padding()
                .navigationTitle("Текст")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { showEditor = false }
                    }
                }
        }
    }
}
