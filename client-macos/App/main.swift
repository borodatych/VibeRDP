// Entry point: the app has no storyboard, so the delegate is installed by hand before the run loop starts
// NSApplication keeps its delegate weakly: this global holds it for the lifetime of the process

import AppKit

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
