import SwiftUI

extension View {
    /// Installs Beadazzle's composition root. Views reach narrower observable domains
    /// through this stable root, so alternate windows and test hosts need one dependency.
    func beadStoreEnvironment(_ store: BeadStore) -> some View {
        environment(store)
    }
}
