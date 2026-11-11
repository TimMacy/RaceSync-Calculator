import SwiftUI
import AppKit

// MARK: - Region selection -

enum RegionSelector {
    /// Covers `screen` with a see-through overlay and reports the rectangle the user drags there:
    /// in points with a top-left origin, relative to that screen. Nil means the selection was canceled.
    static func selectRegion(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let selectionWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        selectionWindow.backgroundColor = NSColor.clear
        selectionWindow.isOpaque = false
        selectionWindow.level = .screenSaver
        selectionWindow.hasShadow = false
        selectionWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        selectionWindow.isMovableByWindowBackground = false
        selectionWindow.isReleasedWhenClosed = false // Swift owns the window's lifetime

        let selectionView = RegionSelectionView(completion: { selectedRect in
            selectionWindow.orderOut(nil)
            selectionWindow.contentView = nil // Break the window/view/completion retain cycle
            selectionWindow.close()
            completion(selectedRect)
        })

        selectionWindow.contentView = NSHostingView(rootView: selectionView)
        selectionWindow.makeKeyAndOrderFront(nil)
    }
}

/// The overlay's content: drag to select, click to cancel.
struct RegionSelectionView: View {
    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    var completion: (CGRect?) -> Void

    var body: some View {
        ZStack {
            // Semi-transparent overlay to capture clicks/drags anywhere
            Color.black.opacity(0.15)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture { // Allow clicking background to cancel
                    if startPoint == nil { // Only cancel if not currently dragging
                        completion(nil)
                    }
                }

            // Draw the selection rectangle dynamically during drag
            if let start = startPoint, let current = currentPoint {
                let selectionRect = makeRect(from: start, to: current)
                Rectangle()
                    .fill(Color.blue.opacity(0.2))
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.8), lineWidth: 1))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
            }

            Text("Drag to select region. Click background to cancel.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                .shadow(radius: 5)
                // Near the top-center of this screen (the overlay's own space, not global screen coordinates)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 44)
                .allowsHitTesting(false)
        }
        .edgesIgnoringSafeArea(.all) // Ensure ZStack covers the entire screen
        .gesture(
            // .global is the overlay window's space: points from its top-left corner, y down.
            // The window covers the screen exactly, so that is also the position on the screen.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startPoint == nil {
                        startPoint = value.startLocation
                    }
                    currentPoint = value.location
                }
                .onEnded { value in
                    if let start = startPoint {
                        let finalRect = makeRect(from: start, to: value.location)
                        if finalRect.width > 5 && finalRect.height > 5 { // Min 5x5 points
                            completion(finalRect)
                        } else {
                            print("Selection too small, canceling.")
                            completion(nil) // Treat very small drags as cancellation
                        }
                    } else {
                        completion(nil)
                    }
                    // Reset state; the window is closed by RegionSelector
                    startPoint = nil
                    currentPoint = nil
                }
        )
    }

    /// The rectangle between two drag points, whichever direction the drag went (top-left origin).
    private func makeRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
        CGRect(x: min(p1.x, p2.x),
               y: min(p1.y, p2.y),
               width: abs(p1.x - p2.x),
               height: abs(p1.y - p2.y))
    }
}