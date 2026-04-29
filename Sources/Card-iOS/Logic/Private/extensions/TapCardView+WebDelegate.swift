//
//  TapCardView+WebDelegate.swift
//  TapCardCheckOutKit
//
//  Created by Osama Rabie on 12/09/2023.
//

import Foundation
import UIKit
import WebKit
import SharedDataModels_iOS

extension TapCardView:WKNavigationDelegate {
    
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var action: WKNavigationActionPolicy?
        
        defer {
            decisionHandler(action ?? .allow)
        }
        
        guard let url = navigationAction.request.url else { return }
        
        if url.absoluteString.hasPrefix("tapcardwebsdk") {
            print("navigationAction", url.absoluteString)
            action = .cancel
        }else{
            print("navigationAction", url.absoluteString)
        }
        
        switch url.absoluteString {
        case _ where url.absoluteString.contains("onReady"):
            handleOnReady()
            break
        case _ where url.absoluteString.contains("onFocus"):
        //handleRedirection(data: "{\"threeDsUrl\":\"https://www.google.com/?client=safari\", \"redirectUrl\":\"https://sdk.dev.tap.company\",\"keyword\":\"auth_payer\"}")
            delegate?.onFocus?()
            break
        case _ where url.absoluteString.contains("onBinIdentification"):
            delegate?.onBinIdentification?(data: tap_extractDataFromUrl(url.absoluteURL))
            // The web SDK only emits `onInvalidInput(false)` on a validity *transition*. When we
            // prefill a complete card, validity goes from invalid to valid on the very first
            // fillCardInputs and never transitions again on subsequent loads against a warm
            // WebView, so the host's `onInvalidInput`-based trigger never fires. Tokenise
            // directly here — by the time `onBinIdentification` arrives, the card is fully
            // accepted by the web SDK and ready to tokenise.
            generateTapToken()
            break
        case _ where url.absoluteString.contains("onInvalidInput"):
            delegate?.onInvalidInput?(invalid: Bool(tap_extractDataFromUrl(url.absoluteURL).lowercased()) ?? false)
            break
        case _ where url.absoluteString.contains("onError"):
            delegate?.onError?(data: tap_extractDataFromUrl(url.absoluteURL))
            break
        case _ where url.absoluteString.contains("onSuccess"):
            delegate?.onSuccess?(data: tap_extractDataFromUrl(url.absoluteURL))
            break
        case _ where url.absoluteString.contains("onScannerClick"):
            scanCard()
            break
        case _ where url.absoluteString.contains("onChangeSaveCardLater"):
            delegate?.onChangeSaveCard?(enabled: Bool(tap_extractDataFromUrl(url.absoluteURL).lowercased()) ?? false)
            break
        case _ where url.absoluteString.contains("onHeightChange"):
            
            let height = Double(tap_extractDataFromUrl(url,shouldBase64Decode: false))
            self.changeHeight(to: height)
            break
        default:
            break
        }
    }
}
