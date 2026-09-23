//
//  RootView.swift
//  Paperbound
//

import SwiftData
import SwiftUI

struct RootView: View {

    @Environment(\.modelContext) private var context
    @Environment(LibraryEnvironment.self) private var library

    var body: some View {
        LibraryView()
            .onOpenURL { url in
                // A PDF opened from Files or a share sheet lands here.
                library.importFiles([url], into: context)
            }
    }
}
