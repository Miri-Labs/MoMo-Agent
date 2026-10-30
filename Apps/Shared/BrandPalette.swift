import SwiftUI

enum MoMoPalette {
    #if os(watchOS)
    // Keep the Watch dark even when its asset compiler omits named-color luminosity variants.
    static let canvas = Color(.sRGB, red: 22.0 / 255, green: 21.0 / 255, blue: 18.0 / 255)
    static let surface = Color(.sRGB, red: 48.0 / 255, green: 44.0 / 255, blue: 38.0 / 255)
    static let ink = Color(.sRGB, red: 243.0 / 255, green: 238.0 / 255, blue: 229.0 / 255)
    #else
    static let canvas = Color("PhoneBackground")
    static let surface = Color("PhoneSurface")
    static let ink = Color("PhoneInk")
    static let muted = Color("PhoneMuted")
    static let line = Color("PhoneLine")
    static let paper = Color("PhonePaper")
    static let success = Color("PhoneSuccess")
    static let successBackground = Color("PhoneSuccessBackground")
    static let failure = Color("PhoneFailure")
    static let failureBackground = Color("PhoneFailureBackground")
    #endif
}
