import SwiftUI

/// The Bands page — the single content-arranging canvas (the reborn Favorites editor). It edits only
/// authored bands (favorites bands, which include AI-command items); the clipboard "live band" is
/// configured on its own feature page and never authored here. Hosted full-bleed in the Hub's detail
/// column, so the 3-pane editor fills the window.
struct BandsPage: View {
    let context: HubContext
    @ObservedObject private var favorites: FavoritesStore

    init(context: HubContext) {
        self.context = context
        _favorites = ObservedObject(wrappedValue: context.favorites)
    }

    var body: some View {
        BandsCanvas(store: favorites)
            .navigationTitle(HubDestination.bands.title)
    }
}
