import SwiftUI
import AVFoundation

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
    @AppStorage("boxHeight") private var boxHeight = 0.36
    @AppStorage("boxOpacity") private var boxOpacity = 0.45
    @AppStorage("countdown") private var countdown = 3

    @State private var showEditor = false
    @State private var showSettings = false
    @State private var counting: Int? = nil
    @State private var dragStart: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                CameraPreview(
                    session: camera.session,
                    ready: camera.ready,
                    mirror: camera.mirror,
                    orientation: camera.orientation,
                    onTap: { camera.focus(at: $0) }
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    prompterBox(height: geo.size.height * boxHeight)
                        .padding(.top, landscape ? 8 : 50)
                    Spacer()
                    controls
                }

                if let c = counting {
                    Text("\(c)")
                        .font(.system(size: 120, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 8)
                }
            }
        }
        .onAppear {
            camera.start()
            prompter.speed = speed
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.updateOrientation()
        }
        .onChange(of: speed) { prompter.speed = $0 }
        .sheet(isPresented: $showEditor) { editor }
        .sheet(isPresented: $showSettings) { settings }
    }

    // MARK: - Телепромптер

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
            .background(Color.black.opacity(boxOpacity))
            .scaleEffect(x: mirrorText ? -1 : 1, y: 1)
            .contentShape(Rectangle())
            .onTapGesture {
                prompter.running ? prompter.pause() : prompter.start()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragStart == nil { dragStart = prompter.offset }
                        prompter.offset = max(0, (dragStart ?? 0) - value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    // MARK: - Управление

    private var controls: some View {
        VStack(spacing: 10) {
            if !camera.activeDescription.isEmpty {
                Text("\(camera.activeDescription) · \(camera.bitrate) Mbps")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            HStack {
                Text("Скорость").font(.caption)
                Slider(value: $speed, in: 10...150)
            }
            HStack(spacing: 10) {
                Button { showEditor = true } label: { icon("pencil") }
                Button { prompter.reset() } label: { icon("backward.end.fill") }
                Button {
                    prompter.running ? prompter.pause() : prompter.start()
                } label: { icon(prompter.running ? "pause.fill" : "play.fill") }

                Button { recordTapped() } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 70, height: 70)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                            .fill(Color.red)
                            .frame(width: camera.isRecording ? 28 : 56, height: camera.isRecording ? 28 : 56)
                    }
                }

                // Зеркало: и превью, и записанный файл
                Button { camera.mirror.toggle() } label: {
                    icon("person.crop.square", active: camera.mirror)
                }
                Button { showSettings = true } label: { icon("gearshape") }
            }
        }
        .padding()
        .background(Color.black.opacity(0.55))
    }

    private func recordTapped() {
        if camera.isRecording {
            camera.toggleRecording()
            prompter.pause()
            return
        }
        if counting != nil { return }
        let seconds = countdown
        if seconds <= 0 {
            startRecording()
            return
        }
        Task { @MainActor in
            for i in stride(from: seconds, to: 0, by: -1) {
                counting = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            counting = nil
            startRecording()
        }
    }

    private func startRecording() {
        camera.toggleRecording()
        prompter.start()
    }

    private func icon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundColor(active ? .yellow : .white)
            .frame(width: 40, height: 44)
    }

    // MARK: - Редактор текста и настройки

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

    private var settings: some View {
        NavigationView {
            Form {
                Section(header: Text("Видео (меняется только вне записи)")) {
                    Picker("Разрешение", selection: $camera.resolution) {
                        Text("1080p").tag(1080)
                        Text("4K").tag(2160)
                    }
                    .pickerStyle(.segmented)

                    Picker("FPS", selection: $camera.fps) {
                        Text("24").tag(24)
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.segmented)

                    Picker("Цвет", selection: $camera.hdr) {
                        Text("HDR (HLG)").tag(true)
                        Text("SDR").tag(false)
                    }
                    .pickerStyle(.segmented)

                    Picker("Битрейт", selection: $camera.bitrate) {
                        ForEach([50, 100, 150, 200], id: \.self) { value in
                            Text("\(value) Мбит/с").tag(value)
                        }
                    }

                    Toggle("Стабилизация", isOn: $camera.stabilization)
                }
                .disabled(camera.isRecording)

                Section(header: Text("Картинка")) {
                    VStack(alignment: .leading) {
                        Text("Яркость (EV): \(camera.exposureBias, specifier: "%.1f")")
                        Slider(value: $camera.exposureBias, in: -2...2, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text("Зум: \(camera.zoom, specifier: "%.2f")×")
                        Slider(value: $camera.zoom, in: 1...3, step: 0.05)
                    }
                }

                Section(header: Text("Телепромптер")) {
                    VStack(alignment: .leading) {
                        Text("Скорость: \(Int(speed))")
                        Slider(value: $speed, in: 10...150)
                    }
                    VStack(alignment: .leading) {
                        Text("Размер шрифта: \(Int(fontSize))")
                        Slider(value: $fontSize, in: 20...64)
                    }
                    VStack(alignment: .leading) {
                        Text("Высота плашки: \(Int(boxHeight * 100))%")
                        Slider(value: $boxHeight, in: 0.2...0.6)
                    }
                    VStack(alignment: .leading) {
                        Text("Прозрачность фона: \(Int(boxOpacity * 100))%")
                        Slider(value: $boxOpacity, in: 0...0.9)
                    }
                    Stepper("Отсчёт перед записью: \(countdown) с", value: $countdown, in: 0...10)
                    Toggle("Зеркальный текст (для стекла)", isOn: $mirrorText)
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showSettings = false }
                }
            }
        }
    }
}
