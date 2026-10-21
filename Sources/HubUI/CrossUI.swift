//
//  File.swift
//  Hub
//
//  Created by Linux on 23.06.26.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif

typealias SwiftUIPicker = Picker
@available(iOS 14.0, tvOS 14.0, macOS 11.0, watchOS 7.0, *)
typealias SwiftUILabel = Label
typealias SwiftUIText = Text
typealias SwiftUIHStack = HStack
typealias SwiftUIVStack = VStack
typealias SwiftUIZStack = ZStack
typealias SwiftUITextField = TextField
@available(tvOS, unavailable)
typealias SwiftUISlider = Slider
typealias SwiftUIForEach = ForEach
typealias SwiftUIList = List
@available(iOS 16.0, tvOS 16.0, macOS 13.0, watchOS 9.0, *)
public typealias SwiftUITransferable = Transferable
@available(iOS 14.0, tvOS 14.0, macOS 11.0, watchOS 7.0, *)
typealias SwiftUILabelStyle = LabelStyle
typealias SwiftUISpacer = Spacer
typealias SwiftUIImage = Image
