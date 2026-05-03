//
//  ContentView.swift
//  ScreenshotBrain
//
//  Created by medha karthi on 2026-05-03.
//

import SwiftUI
import PhotosUI
@preconcurrency import Vision

/// Main screen: pick a screenshot, preview it, and read text with Vision (on-device OCR).
struct ContentView: View {

    // MARK: - State

    /// The item the user picked in the system photo picker (nil until they choose something).
    @State private var selectedItem: PhotosPickerItem?

    /// Decoded image for preview and OCR. Only set after the user picks a photo.
    @State private var selectedImage: UIImage?

    /// Text Vision found in the image.
    @State private var extractedText: String = ""

    /// Shown while Vision is working so the UI does not feel frozen.
    @State private var isRecognizingText = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Pick a photo (manual only)

                    // PhotosPicker opens the system picker when tapped.
                    // Nothing is read from the library until the user selects an image.
                    PhotosPicker(
                        selection: $selectedItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Choose screenshot", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the photo picker to choose one image.")

                    // MARK: Image preview

                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                    } else {
                        Text("Tap the button above to pick a screenshot. Your library is not scanned automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // MARK: OCR status

                    if isRecognizingText {
                        HStack {
                            ProgressView()
                            Text("Reading text from image…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // MARK: Extracted text (scrolls with the rest of the page)

                    Text("Extracted text")
                        .font(.headline)

                    // Long text stays readable inside the outer ScrollView.
                    Text(displayedExtractedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .padding()
            }
            .navigationTitle("ScreenshotBrain")
        }
        // When the user picks a different item, load the image and run OCR.
        .onChange(of: selectedItem) { _, newItem in
            Task {
                await handleSelectionChange(newItem)
            }
        }
    }

    /// Text shown under “Extracted text” depending on state.
    private var displayedExtractedText: String {
        if selectedImage == nil {
            return "Choose an image to see text here."
        }
        if isRecognizingText {
            return ""
        }
        if extractedText.isEmpty {
            return "No text was detected in this image."
        }
        return extractedText
    }

    // MARK: - Load image + OCR

    /// Loads image data from the picker item, updates the preview, then runs Vision OCR.
    private func handleSelectionChange(_ item: PhotosPickerItem?) async {
        guard let item else {
            selectedImage = nil
            extractedText = ""
            isRecognizingText = false
            return
        }

        // loadTransferable runs async I/O: fetch bytes for the one item the user chose.
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            selectedImage = nil
            extractedText = ""
            isRecognizingText = false
            return
        }

        selectedImage = image
        extractedText = ""
        isRecognizingText = true

        // Vision work is CPU/GPU heavy; do it off the main thread, then update UI.
        let text = await recognizeText(in: image)

        extractedText = text
        isRecognizingText = false
    }

    /// Uses Apple Vision’s text recognizer to read strings from a UIImage.
    private func recognizeText(in image: UIImage) async -> String {
        // Vision needs a CGImage. Most photos provide one; if not, OCR cannot run.
        guard let cgImage = image.cgImage else {
            return ""
        }

        // withCheckedContinuation bridges Vision’s callback API into async/await.
        return await withCheckedContinuation { continuation in
            // VNRecognizeTextRequest finds text regions and returns candidate strings.
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(returning: "Could not read text: \(error.localizedDescription)")
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []

                // Take the best guess for each line/region and join with newlines.
                let lines = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: lines.joined(separator: "\n"))
            }

            // .accurate is slower but better for screenshots; .fast is snappier on large photos.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            // Vision can take a moment; keep the main thread free for scrolling and animations.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "Vision error: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
