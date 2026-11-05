import SwiftUI
import PhotosUI

struct DemoPhotoEntryView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingEditor = false

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            entryButton
        }
        .buttonStyle(.plain)
        .onChange(of: pickerItem) { _, item in
            guard item != nil else { return }
            isShowingEditor = true
        }
        .fullScreenCover(isPresented: $isShowingEditor, onDismiss: {
            pickerItem = nil
        }) {
            if let item = pickerItem {
                DemoPhotoAutoEnhanceView(initialPickerItem: item)
            }
        }
    }

    private var entryButton: some View {
        HStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 52, height: 52)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Demo").font(.headline).foregroundStyle(AppTheme.primaryText)
                Text("选择照片，直接进入全屏编辑器")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }
}
