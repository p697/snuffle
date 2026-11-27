import PhotosUI
import SnuffleKit
import SwiftUI
import UIKit

/// The project's square: its picture when the person chose one, otherwise the first letter on its colour.
struct ProjectBadge: View {
    var project: Project
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        Group {
            if let image = ProjectIcons.image(for: project) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(project.monogram)
                    .font(.system(size: size * 0.54, weight: .heavy))
                    .foregroundStyle(project.tint.textColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(project.tint.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// Project pictures on disk, cropped square and kept small. Read through a cache so lists do not decode them again.
enum ProjectIcons {
    private static let cache = NSCache<NSString, UIImage>()
    static let pixelSize: CGFloat = 256

    static func image(for project: Project) -> UIImage? {
        guard let version = project.iconVersion else { return nil }
        let key = "\(project.id.uuidString)-\(version)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = UIImage(contentsOfFile: SharedContainer.projectIcon(project.id, version: version).path()) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Saves a picture for the project and returns the version to store on it.
    static func save(_ image: UIImage, for project: Project) throws -> Int {
        guard let staged = stage(image, for: project) else { throw CocoaError(.fileWriteUnknown) }
        try write(staged.data, for: project.id, version: staged.version)
        return staged.version
    }

    /// A picture for a project not saved yet: shown from memory under the next version, written by `write` once the
    /// project is kept, so a project that is not leaves nothing behind.
    static func stage(_ image: UIImage, for project: Project) -> (version: Int, data: Data)? {
        let version = (project.iconVersion ?? 0) + 1
        let square = squared(image)
        guard let data = square.jpegData(compressionQuality: 0.85) else { return nil }
        cache.setObject(square, forKey: "\(project.id.uuidString)-\(version)" as NSString)
        return (version, data)
    }

    static func write(_ data: Data, for projectId: UUID, version: Int) throws {
        let url = SharedContainer.projectIcon(projectId, version: version)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The centre square, scaled down to `pixelSize`.
    private static func squared(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2)
        let target = CGSize(width: pixelSize, height: pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = pixelSize / side
            image.draw(in: CGRect(x: origin.x * scale, y: origin.y * scale, width: image.size.width * scale, height: image.size.height * scale))
        }
    }
}

/// The badge with a small camera: choose a photo, take one, or go back to the letter.
struct ProjectIconPicker: View {
    @Binding var project: Project
    var size: CGFloat = 56
    @Environment(\.accent) private var accent
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var error: String?

    var body: some View {
        Menu {
            Button("从相册选", systemImage: "photo") { choosingPhoto = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍一张", systemImage: "camera") { takingPhoto = true }
            }
            if project.iconVersion != nil {
                Button("用回首字母", systemImage: "textformat") { project.iconVersion = nil }
            }
        } label: {
            ProjectBadge(project: project, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 26, height: 26)
                        .background(accent, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
                        .offset(x: 7, y: 7)
                }
                .frame(width: size + 8, height: size + 8, alignment: .topLeading)
        }
        .accessibilityLabel("更换项目图标")
        .accessibilityIdentifier("projectIcon")
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    error = String(localized: "读不出这张图片")
                    return
                }
                use(image)
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takingPhoto = false
                if let image { use(image) }
            }
            .ignoresSafeArea()
        }
        .alert("没能换图标", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func use(_ image: UIImage) {
        do {
            project.iconVersion = try ProjectIcons.save(image, for: project)
        } catch {
            self.error = describe(error)
        }
    }
}

/// The system camera, for "拍一张".
private struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.editedImage] ?? info[.originalImage]) as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
