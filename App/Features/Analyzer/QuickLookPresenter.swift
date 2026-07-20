// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import QuickLookUI

@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()

    private var items: [NSURL] = []

    func preview(_ url: URL) {
        items = [url as NSURL]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index]
    }
}
