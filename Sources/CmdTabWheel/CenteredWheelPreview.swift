import SwiftUI

/// Only the picture participates in centering; captions are anchored outside its bounds.
struct CenteredWheelPreview<Picture: View, Header: View, Footer: View>: View {
    private let picture: Picture
    private let header: Header
    private let footer: Footer

    init(@ViewBuilder picture: () -> Picture,
         @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.picture = picture()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        picture
            .overlay(alignment: .top) {
                header
                    .padding(.bottom, 10)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
            .overlay(alignment: .bottom) {
                footer
                    .padding(.top, 10)
                    .alignmentGuide(.bottom) { $0[.top] }
            }
    }
}
