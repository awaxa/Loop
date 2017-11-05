//
//  UIColor.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/23/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit


extension UIColor {
    @nonobjc static var tintColor: UIColor? = nil

    @nonobjc static let secondaryLabelColor = UIColor.HIGGrayColor()

    @nonobjc static let cellBackgroundColor = UIColor(white: 239 / 255, alpha: 1)

    @nonobjc static let IOBTintColor = UIColor(red: 0 / 255, green: 153 / 255, blue: 255 / 255, alpha: 1)

    @nonobjc static let COBTintColor = UIColor(red: 255 / 255, green: 0 / 255, blue: 197 / 255, alpha: 1)

    @nonobjc static let agingColor = UIColor(red: 239 / 255, green: 171 / 255, blue: 255 / 255, alpha: 1)

    @nonobjc static let staleColor = UIColor(red: 184 / 255, green: 212 / 255, blue: 230 / 255, alpha: 1)

    @nonobjc static let unknownColor = UIColor(red: 198 / 255, green: 199 / 255, blue: 201 / 255, alpha: 1)

    @nonobjc static let deleteColor = UIColor.HIGRedColor()

    @nonobjc static let purpleColor = UIColor(red: 159 / 255, green: 0 / 255, blue: 197 / 255, alpha: 1)

    @nonobjc static let blueColor = UIColor(red: 0 / 255, green: 153 / 255, blue: 255 / 255, alpha: 1)
}
