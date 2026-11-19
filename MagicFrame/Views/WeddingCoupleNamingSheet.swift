import SwiftUI
import UIKit

/// After confirming AI Wedding: name bride/groom on the couple-only photo (not a people list).
struct WeddingCoupleNamingSheet: View {

    let photoId: String
    let faces: [PhotoFaceAnnotation]
    let defaultWeddingDate: Date
    let onComplete: (
        _ brideFaceId: Int,
        _ brideName: String,
        _ groomFaceId: Int,
        _ groomName: String,
        _ weddingDate: Date
    ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var brideFaceId: Int?
    @State private var groomFaceId: Int?
    @State private var brideName = ""
    @State private var groomName = ""
    @State private var weddingDate: Date
    @State private var namingRole: Role?

    private enum Role: String, Identifiable {
        case bride
        case groom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    init(
        photoId: String,
        faces: [PhotoFaceAnnotation],
        defaultWeddingDate: Date,
        onComplete: @escaping (Int, String, Int, String, Date) -> Void
    ) {
        self.photoId = photoId
        self.faces = Array(faces.prefix(2))
        self.defaultWeddingDate = defaultWeddingDate
        self.onComplete = onComplete
        _weddingDate = State(initialValue: defaultWeddingDate)
        let sorted = faces.sorted { $0.bboxX < $1.bboxX }
        if sorted.count >= 2 {
            _brideFaceId = State(initialValue: sorted[0].faceInstanceId)
            _groomFaceId = State(initialValue: sorted[1].faceInstanceId)
            _brideName = State(initialValue: sorted[0].personDisplayName ?? "")
            _groomName = State(initialValue: sorted[1].personDisplayName ?? "")
        } else if let only = sorted.first {
            _brideFaceId = State(initialValue: only.faceInstanceId)
            _brideName = State(initialValue: only.personDisplayName ?? "")
        }
    }

    private var canSave: Bool {
        guard let brideFaceId, let groomFaceId, brideFaceId != groomFaceId else { return false }
        let b = brideName.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = groomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !b.isEmpty && !g.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tap each face to name the bride and groom.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    photoWithFaces
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                    roleRow(role: .bride, name: brideName, faceId: brideFaceId)
                    roleRow(role: .groom, name: groomName, faceId: groomFaceId)

                    Button("Swap Bride & Groom") {
                        swapRoles()
                    }
                    .padding(.horizontal)

                    DatePicker(
                        "Wedding date",
                        selection: $weddingDate,
                        displayedComponents: .date
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Name Couple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .task {
                if let cg = await PhotoAssetImageLoader.loadCGImage(
                    assetIdentifier: photoId,
                    targetPixelSize: 1200
                ) {
                    image = UIImage(cgImage: cg)
                }
            }
            .alert(
                namingRole.map { "Name \($0.title)" } ?? "Name",
                isPresented: Binding(
                    get: { namingRole != nil },
                    set: { if !$0 { namingRole = nil } }
                )
            ) {
                TextField("Name", text: nameBindingForAlert)
                Button("OK") { namingRole = nil }
                Button("Cancel", role: .cancel) { namingRole = nil }
            }
        }
    }

    private var photoWithFaces: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(faces) { face in
                    let rect = faceRect(face: face, in: geo.size)
                    Button {
                        if face.faceInstanceId == brideFaceId {
                            namingRole = .bride
                        } else if face.faceInstanceId == groomFaceId {
                            namingRole = .groom
                        } else if brideFaceId == nil {
                            brideFaceId = face.faceInstanceId
                            namingRole = .bride
                        } else {
                            groomFaceId = face.faceInstanceId
                            namingRole = .groom
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(roleColor(for: face.faceInstanceId), lineWidth: 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(roleColor(for: face.faceInstanceId).opacity(0.15))
                            )
                            .overlay(alignment: .top) {
                                Text(roleLabel(for: face.faceInstanceId))
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .offset(y: -22)
                            }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private var nameBindingForAlert: Binding<String> {
        Binding(
            get: {
                switch namingRole {
                case .bride: return brideName
                case .groom: return groomName
                case .none: return ""
                }
            },
            set: { newValue in
                switch namingRole {
                case .bride: brideName = newValue
                case .groom: groomName = newValue
                case .none: break
                }
            }
        )
    }

    private func roleRow(role: Role, name: String, faceId: Int?) -> some View {
        HStack {
            Text(role.title)
                .font(.headline)
                .frame(width: 64, alignment: .leading)
            Text(name.isEmpty ? "Tap face to name" : name)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
            Spacer()
            if faceId != nil {
                Button("Edit") { namingRole = role }
            }
        }
        .padding(.horizontal)
    }

    private func roleColor(for faceId: Int) -> Color {
        if faceId == brideFaceId { return .pink }
        if faceId == groomFaceId { return .blue }
        return .yellow
    }

    private func roleLabel(for faceId: Int) -> String {
        if faceId == brideFaceId { return brideName.isEmpty ? "Bride" : brideName }
        if faceId == groomFaceId { return groomName.isEmpty ? "Groom" : groomName }
        return "Tap"
    }

    /// Vision bbox is normalized with origin bottom-left; convert to SwiftUI top-left in fitted image.
    private func faceRect(face: PhotoFaceAnnotation, in container: CGSize) -> CGRect {
        let imageSize: CGSize
        if let image {
            let scale = min(
                container.width / max(image.size.width, 1),
                container.height / max(image.size.height, 1)
            )
            imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        } else {
            imageSize = container
        }
        let originX = (container.width - imageSize.width) / 2
        let originY = (container.height - imageSize.height) / 2
        let box = face.faceBoundingBox
        let x = originX + CGFloat(box.origin.x) * imageSize.width
        let y = originY + (1 - CGFloat(box.origin.y) - CGFloat(box.height)) * imageSize.height
        let w = CGFloat(box.width) * imageSize.width
        let h = CGFloat(box.height) * imageSize.height
        return CGRect(x: x, y: y, width: max(w, 24), height: max(h, 24))
    }

    private func swapRoles() {
        swap(&brideFaceId, &groomFaceId)
        swap(&brideName, &groomName)
    }

    private func save() {
        guard let brideFaceId, let groomFaceId else { return }
        let b = brideName.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = groomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !g.isEmpty else { return }
        onComplete(brideFaceId, b, groomFaceId, g, weddingDate)
        dismiss()
    }
}
