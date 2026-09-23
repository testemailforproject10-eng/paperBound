//
//  BookTileView.swift
//  Paperbound
//
//  One book on the shelf. The cover is shown inside the book presentation the
//  reader chose for it, so the shelf hints at how the book will actually look.
//

import SwiftUI
import UIKit

struct BookTileView: View {

    let book: Book
    let environment: ReadingEnvironment
    let width: CGFloat

    private var height: CGFloat { width * 1.42 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.displayAuthor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            progress
        }
        .frame(width: width)
    }

    // MARK: - Cover

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(environment.material.baseColor.swiftUIColor)

            if let data = book.coverData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .blendMode(environment.material.invertsInk ? .normal : .multiply)
                    .opacity(environment.material.invertsInk ? 0.85 : 1)
            } else {
                generatedCover
            }

            // Spine.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.16)
            .frame(maxWidth: .infinity, alignment: .leading)

            if book.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if book.isFinished {
                Text("Finished")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 5, x: 1, y: 3)
    }

    private var generatedCover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(book.title)
                .font(.system(size: max(11, width * 0.11), weight: .semibold, design: .serif))
                .foregroundStyle(inkColor)
                .lineLimit(4)
            Rectangle()
                .fill(inkColor.opacity(0.5))
                .frame(width: width * 0.4, height: 1)
            Text(book.displayAuthor)
                .font(.system(size: max(8, width * 0.075), design: .serif))
                .foregroundStyle(inkColor.opacity(0.75))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(book.format.displayName)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(inkColor.opacity(0.5))
        }
        .padding(.horizontal, width * 0.13)
        .padding(.vertical, width * 0.12)
        .frame(width: width, height: height, alignment: .leading)
    }

    private var inkColor: Color {
        environment.material.invertsInk
            ? Color(white: 0.88)
            : Color(red: 0.13, green: 0.11, blue: 0.09)
    }

    // MARK: - Progress

    @ViewBuilder
    private var progress: some View {
        if book.progress > 0.001 && !book.isFinished {
            HStack(spacing: 6) {
                ProgressView(value: book.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("\(Int((book.progress * 100).rounded()))%")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Color.clear.frame(height: 8)
        }
    }
}
