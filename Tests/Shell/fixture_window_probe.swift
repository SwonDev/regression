import CoreGraphics
import Foundation

let expectedOwner = "Regression"
let expectedTitle = "Regression Visual Fixture"
let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? []

let fixtureWindow = windowInfo.first { window in
  guard let owner = window[kCGWindowOwnerName] as? String,
        let title = window[kCGWindowName] as? String else {
    return false
  }
  return owner == expectedOwner && title == expectedTitle
}

guard let fixtureWindow,
      let windowNumber = fixtureWindow[kCGWindowNumber] as? CGWindowID else {
  exit(1)
}

print(windowNumber)
