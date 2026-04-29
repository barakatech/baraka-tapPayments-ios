//
//  WebCardView.swift
//  TapCardCheckOutKit
//
//  Created by MahmoudShaabanAllam on 07/09/2023.
//

import UIKit
import WebKit
import SharedDataModels_iOS
import Foundation
import TapCardScannerWebWrapper_iOS
import AVFoundation

/// The custom view that provides an interface for the Tap card sdk form
@objc public class TapCardView: UIView {
    /// The web view used to render the tap card sdk
    internal var webView: WKWebView?
    /// The detected IP of the device
    internal var detectedIP:String = ""
    /// A protocol that allows integrators to get notified from events fired from Tap card sdk
    internal var delegate: TapCardViewDelegate?
    /// Holds a reference to the prefilling card number if  any
    internal var cardNumber:String = ""
    /// Holds a reference to the prefilling card expiry if  any
    internal var cardExpiry:String = ""
    /// Holds a reference to the prefilling card cvv if any
    internal var cardCVV: String = ""
    /// Holds a reference to the prefilling card holder name if any
    internal var cardHolderName: String = ""
    /// Defines the base url for the Tap card sdk
    internal static var tapCardBaseUrl:String = "https://sdk.beta.tap.company/v2/card/wrapper?configurations="
    internal static var sandboxKey:String = """
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8AX++RtxPZFtns4XzXFlDIxPB
h0umN4qRXZaKDIlb6a3MknaB7psJWmf2l+e4Cfh9b5tey/+rZqpQ065eXTZfGCAu
BLt+fYLQBhLfjRpk8S6hlIzc1Kdjg65uqzMwcTd0p7I4KLwHk1I0oXzuEu53fU1L
SZhWp4Mnd6wjVgXAsQIDAQAB
-----END PUBLIC KEY-----
"""
    internal static var productionKey:String = """
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8AX++RtxPZFtns4XzXFlDIxPB
h0umN4qRXZaKDIlb6a3MknaB7psJWmf2l+e4Cfh9b5tey/+rZqpQ065eXTZfGCAu
BLt+fYLQBhLfjRpk8S6hlIzc1Kdjg65uqzMwcTd0p7I4KLwHk1I0oXzuEu53fU1L
SZhWp4Mnd6wjVgXAsQIDAQAB
-----END PUBLIC KEY-----
"""
    /// Defines the scanner object to be called whenever needed
    internal var fullScanner:TapFullScreenScannerViewController?
    /// Defines the UIViewController passed from the parent app to present the scanner controller within
    internal var presentScannerIn:UIViewController? = nil
    /// keeps a hold of the loaded web sdk configurations url
    internal var currentlyLoadedCardConfigurations:URL?
    /// holds the initial width
    internal var initialWidth:CGFloat = 0
    /// Reference to the in-flight geolocation request, kept so we can cancel on deinit
    internal var ipFetchTask: URLSessionDataTask?
    /// Whether the geolocation request has completed (success or failure)
    internal var ipFetched: Bool = false
    /// Pending completions waiting for the in-flight geolocation request to settle.
    /// Lets concurrent callers attach to the existing request instead of issuing a parallel one.
    internal var ipPendingCompletions: [() -> Void] = []
    /// Tracks whether the web SDK signalled `onReady` for the current load. Reset on each new load.
    internal var didReceiveOnReady: Bool = false
    /// Watchdog scheduled after each load. If `onReady` does not arrive in time we reload once.
    internal var onReadyWatchdog: DispatchWorkItem?
    /// Guards against an infinite reload loop when the web SDK never signals `onReady`.
    internal var didRetryAfterWatchdog: Bool = false
    /// The headers encryption key
    internal var headersEncryptionPublicKey:String {
        if getCardKey().contains("test") {
            return TapCardView.sandboxKey
        }else{
            return TapCardView.productionKey
        }
    }
    //MARK: - Init methods
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    deinit {
        ipFetchTask?.cancel()
        onReadyWatchdog?.cancel()
    }
    
    //MARK: - Private methods
    /// Used as a consolidated method to do all the needed steps upon creating the view
    private func commonInit() {
        setupWebView()
        setupConstraints()
        getIP()
    }
    
    
    /// Used to open a url inside the Tap card web sdk.
    /// - Parameter url: The url needed to load.
    private func openUrl(url: URL?) {
        // Store it for further usages
        currentlyLoadedCardConfigurations = url
        // instruct the web view to load the needed url. The wrapper endpoint redirects internally
        // to `index.html`; we ignore caches so the redirect chain is identical on the very first
        // attempt and on subsequent ones (otherwise the first attempt occasionally never emits
        // `onReady`, leaving the host UI stuck on its loader).
        var request = URLRequest(url: url!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(TapApplicationPlistInfo.shared.bundleIdentifier ?? "", forHTTPHeaderField: "referer")
        // Reset the readiness state for this new load and arm a watchdog so we can recover if
        // the web SDK never reports back.
        didReceiveOnReady = false
        scheduleOnReadyWatchdog()
        DispatchQueue.main.async {
            self.webView?.navigationDelegate = self
            self.webView?.load(request)
        }
    }

    /// Arms a watchdog that triggers a single reload if `onReady` is not reported within the
    /// expected window. Symptom we are guarding against: the wrapper page redirects to
    /// `index.html` but the JS bridge never fires `tapcardwebsdk://onReady`, leaving the host
    /// app in an infinite loading state.
    private func scheduleOnReadyWatchdog() {
        onReadyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.didReceiveOnReady else { return }
            guard !self.didRetryAfterWatchdog,
                  let url = self.currentlyLoadedCardConfigurations else {
                // Already retried once — surface the failure rather than reloading forever.
                self.delegate?.onError?(data: "{\"error\":\"Tap card SDK did not signal onReady in time.\"}")
                return
            }
            self.didRetryAfterWatchdog = true
            var retry = URLRequest(url: url)
            retry.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            retry.setValue(TapApplicationPlistInfo.shared.bundleIdentifier ?? "", forHTTPHeaderField: "referer")
            self.webView?.load(retry)
            self.scheduleOnReadyWatchdog()
        }
        onReadyWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
    
    /// used to setup the constraint of the Tap card sdk view
    private func setupWebView() {
        // Creates needed configuration for the web view
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        // Let us make sure it is of a clear background and opaque, not to interfer with the merchant's app background
        webView?.isOpaque = false
        webView?.backgroundColor = UIColor.clear
        webView?.scrollView.backgroundColor = UIColor.clear
        webView?.scrollView.bounces = false
        webView?.isHidden = false
        // Let us add it to the view
        self.backgroundColor = .clear
        self.addSubview(webView!)
    }
    
    
    /// Setup Constaraints for the sub views.
    private func setupConstraints() {
        // Defensive coding
        guard let webView = self.webView else {
            return
        }
        
        // Preprocessing needed setup
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // Define the web view constraints
        let top  = webView.topAnchor.constraint(equalTo: self.topAnchor)
        let left = webView.leftAnchor.constraint(equalTo: self.leftAnchor, constant: 4)
        let right = webView.rightAnchor.constraint(equalTo: self.rightAnchor, constant: -4)
        let bottom = webView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        let cardHeight = self.heightAnchor.constraint(equalToConstant: 95)
        let cardWidth = self.widthAnchor.constraint(equalToConstant: self.frame.width)
        
        // Activate the constraints
        constraints.first { $0.firstAnchor == heightAnchor }?.isActive = false
        constraints.first { $0.firstAnchor == widthAnchor }?.isActive = false
        
        NSLayoutConstraint.activate([left, right, top, bottom, cardHeight,cardWidth])
        DispatchQueue.main.async {
            /*let currentWidth:CGFloat = self.frame.width
            self.snp.remakeConstraints { make in
                make.height.equalTo(95)
                make.width.equalTo(currentWidth)
            }
            
            self.webView?.snp.remakeConstraints { make in
                make.leading.equalToSuperview()
                make.trailing.equalToSuperview()
                make.top.equalToSuperview()
                make.bottom.equalToSuperview()
            }
            */
            self.layoutIfNeeded()
            self.updateConstraints()
            self.layoutSubviews()
            self.initialWidth = self.frame.width
            self.webView?.layoutIfNeeded()
        }
        
    }
    
    
    /// Fetches the IP of the device.
    /// - Parameter completion: Invoked on the main thread once the request finishes (success or failure),
    ///   so callers can sequence work that depends on `detectedIP` being populated.
    ///
    /// If a request is already in flight, the completion is queued and will be invoked when that
    /// existing request settles. This avoids racing two parallel `URLSessionDataTask`s when
    /// `commonInit()` and `initTapCardSDK()` are called back-to-back.
    internal func getIP(completion: (() -> Void)? = nil) {
        if ipFetched {
            DispatchQueue.main.async { completion?() }
            return
        }
        if let completion = completion {
            ipPendingCompletions.append(completion)
        }
        // Already fetching — the in-flight task will drain `ipPendingCompletions` for us.
        guard ipFetchTask == nil else { return }

        var geoRequest = URLRequest(url: URL(string: "https://geolocation-db.com/json/")!)
        geoRequest.timeoutInterval = 10
        ipFetchTask = URLSession.shared.dataTask(with: geoRequest) { [weak self] data, _, _ in
            guard let self = self else { return }
            defer {
                self.ipFetched = true
                self.ipFetchTask = nil
                let pending = self.ipPendingCompletions
                self.ipPendingCompletions.removeAll()
                DispatchQueue.main.async { pending.forEach { $0() } }
            }
            guard let data = data,
                  let jsonIP = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any],
                  let ipString = jsonIP["IPv4"] as? String else { return }
            self.detectedIP = ipString
        }
        ipFetchTask?.resume()
    }
    
    /// Auto adjusts the height of the card view
    /// - Parameter to newHeight: The new height the card view should expand/shrink to
    internal func changeHeight(to newHeight:Double?) {
        // make sure we are in the main thread
        DispatchQueue.main.async {
            // move to the new height or safely to the default height
            let currentWidth:CGFloat = self.frame.width
            
            let cardHeight = self.heightAnchor.constraint(equalToConstant: (newHeight ?? 95) + 10.0)
            let cardWidth = self.widthAnchor.constraint(equalToConstant: currentWidth)
            
            // Activate the constraints
            self.constraints.first { $0.firstAnchor == self.heightAnchor }?.isActive = false
            self.constraints.first { $0.firstAnchor == self.widthAnchor }?.isActive = false
            NSLayoutConstraint.activate([cardHeight,cardWidth])
            // Update the layout of the affected views
            self.layoutIfNeeded()
            self.updateConstraints()
            self.layoutSubviews()
            self.webView?.layoutIfNeeded()
            self.delegate?.onHeightChange?(height: newHeight ?? 95)
        }
    }
    
    
    /// Will handle passing the scanned data to the web based sdk
    /// - Parameter with scannedCard: The card data needed to be passed to the web card sdk
    internal func handleScanner(with scannedCard:TapCard) {
        webView?.evaluateJavaScript("window.fillCardInputs({cardNumber: '\(scannedCard.tapCardNumber ?? "")',expiryDate: '\(scannedCard.tapCardExpiryMonth ?? "")/\(scannedCard.tapCardExpiryYear ?? "")',cvv: '\(scannedCard.tapCardCVV ?? "")',cardHolderName: '\(scannedCard.tapCardName ?? "")'})")
    }
    
    /// Will do needed logic post getting a message from the web sdk that it is ready to be displayd
    internal func handleOnReady() {
        DispatchQueue.main.async {
            self.didReceiveOnReady = true
            self.onReadyWatchdog?.cancel()
            self.onReadyWatchdog = nil
            self.delegate?.onReady?()
            // IP must be set before card inputs are filled, otherwise the JS-side
            // BIN identification request fires without IP context. We chain through
            // `evaluateJavaScript`'s completion handler to guarantee ordering on the
            // JS side — without this, `window.setIP(...)` and `window.fillCardInputs(...)`
            // race and the prefill path never emits `onInvalidInput(false)` on the very
            // first attempt, leaving the host stuck waiting for tokenisation.
            if !self.detectedIP.isEmpty {
                self.webView?.evaluateJavaScript("window.setIP('\(self.detectedIP)')") { [weak self] _, _ in
                    self?.prefillCardData()
                }
            } else {
                self.prefillCardData()
            }
        }
    }
    
    /// Will check if card number and expiry are passed by merchant, will ask the web sdk to fill them in
    internal func prefillCardData() {
        guard cardNumber.count > 9 else {
            cardNumber = ""
            cardExpiry = ""
            cardCVV = ""
            cardHolderName = ""
            return
        }
        webView?.evaluateJavaScript("window.fillCardInputs({cardNumber: '\(cardNumber)',expiryDate: '\(cardExpiry)',cvv: '\(cardCVV)',cardHolderName: '\(cardHolderName)'})")
        cardNumber = ""
        cardExpiry = ""
        cardCVV = ""
        cardHolderName = ""
    }
    
    /// Tells the web sdk the process is finished with the data from backend
    /// - Parameter rediectionUrl: The url with the needed data coming from back end at the end of the currently running process
    internal func passRedirectionDataToSDK(rediectionUrl:String) {
        webView?.evaluateJavaScript("window.loadAuthentication('\(rediectionUrl)')")
        //generateTapToken()
    }
    
    
    /// Starts the scanning process if all requirements are met
    internal func scanCard() {
        //Make sure we have something to present within
        guard let presentScannerIn = presentScannerIn else {
            let error:[String:String] = ["error":"In order to be able to use the scanner, you need to reconfigure the card and pass presentScannerIn"]
            delegate?.onError?(data: String(data: try! JSONSerialization.data(
                withJSONObject: error,
                options: []), encoding: .utf8) ?? "In order to be able to use the scanner, you need to reconfigure the card and pass presentScannerIn")
            return }
        let scannerController:TapScannerViewController = .init()
        scannerController.delegate = self
        //scannerController.modalPresentationStyle = .overCurrentContext
        // Second grant the authorization to use the camera
        AVCaptureDevice.requestAccess(for: AVMediaType.video) { response in
            if response {
                //access granted
                DispatchQueue.main.async {
                    presentScannerIn.present(scannerController, animated: true)
                    //SwiftEntryKit.display(entry: scannerController, using: ThreeDSView().swiftEntryAttributes())
                }
            }else {
                self.delegate?.onError?(data: "{\"error\":\"The user didn't approve accessing the camera.\"}")
            }
        }
    }
    
    //MARK: - Public init methods
    /*///  configures the tap card sdk with the needed configurations for it to work
    ///  - Parameter config: The configurations model
    ///  - Parameter delegate:A protocol that allows integrators to get notified from events fired from Tap card sdk
    ///  - Parameter presentScannerIn: We will need a reference to the controller that we can present from the card scanner feature
    @objc public func initTapCardSDK(config: TapCardConfiguration, delegate: TapCardViewDelegate? = nil, presentScannerIn:UIViewController? = nil) {
        self.delegate = delegate
        config.operatorModel = .init(publicKey: config.publicKey, metadata: generateApplicationHeader())
        
        self.presentScannerIn = presentScannerIn
        do {
            try openUrl(url: URL(string: generateTapCardSdkURL(from: config)))
        }catch {
            self.delegate?.onError?(data: "{error:\(error.localizedDescription)}")
        }
    }*/
    
    ///  configures the tap card sdk with the needed configurations for it to work
    ///  - Parameter config: The configurations dctionary. Recommended, as it will make you able to customly add models without updating
    ///  - Parameter delegate:A protocol that allows integrators to get notified from events fired from Tap card sdk
    ///  - Parameter presentScannerIn: We will need a reference to the controller that we can present from the card scanner feature
    @objc public func initTapCardSDK(configDict: [String : Any], delegate: TapCardViewDelegate? = nil, presentScannerIn:UIViewController? = nil, cardNumber:String = "", cardExpiry:String = "", cardCVV:String = "", cardHolderName:String = "") {
        
        self.delegate = delegate
        self.presentScannerIn = presentScannerIn ?? self.parentViewController
        // Remove any non numerical charachters for passed card number and date
        self.cardNumber = cardNumber.tap_byRemovingAllCharactersExcept("0123456789")
        self.cardExpiry = cardExpiry.tap_byRemovingAllCharactersExcept("0123456789/")
        self.cardCVV = cardCVV.tap_byRemovingAllCharactersExcept("0123456789")
        self.cardHolderName = cardHolderName
        
        // We will have to add app related information to the request
        var updatedConfigurations:[String:Any] = configDict
        updatedConfigurations["headers"] = generateApplicationHeader()
        updatedConfigurations["sdkVersion"] = "1"
        // We will have to force NFC to false in iOS
        self.update(dictionary: &updatedConfigurations, at: ["features","alternativeCardInputs","cardNFC"], with: false)
        
        // Wait for the geolocation request to settle before loading the iframe.
        // Without this, the BIN identification call fires with an empty IP on the
        // very first tokenisation attempt (race condition: geolocation-db.com has
        // not responded yet). Mirrors the Android SDK which awaits getDeviceLocation().
        let proceed = { [weak self] in
            guard let self = self else { return }
            // Then we need to load base url and encryption keys from cdn
            // We will first need to try to load the latest base url from the CDN to make sure our backend doesn't want us to look somewhere else
            if let url = URL(string: "https://tap-sdks.b-cdn.net/mobile/card/1.0.3/base_url.json") {
                var cdnRequest = URLRequest(url: url)
                cdnRequest.timeoutInterval = 2
                cdnRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                URLSession.shared.dataTask(with: cdnRequest) { [weak self] data, _, _ in
                    guard let self = self else { return }
                    self.setLoadedDataFromCDN(data: data)
                    self.postLoadingFromCDN(configDict: updatedConfigurations, delegate: delegate)
                }.resume()
            } else {
                self.postLoadingFromCDN(configDict: updatedConfigurations, delegate: delegate)
            }
        }

        if ipFetched {
            proceed()
        } else {
            getIP { proceed() }
        }
    }
    
    /// Saves the data loaded from the CDN to be used afterwards
    /// - Parameter data: The data loaded from the CDN file
    internal func setLoadedDataFromCDN(data: Data?) {
        if let data = data {
            do {
                if let cdnResponse:[String:String] = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String],
                   let cdnBaseUrlString:String = cdnResponse["baseURL"], cdnBaseUrlString != "",
                   let cdnBaseUrl:URL = URL(string: cdnBaseUrlString),
                   let sandboxEncryptionKey:String = cdnResponse["testEncKey"],
                   let productionEncryptionKey:String = cdnResponse["prodEncKey"] {
                    TapCardView.sandboxKey = sandboxEncryptionKey
                    TapCardView.productionKey = productionEncryptionKey
                    TapCardView.tapCardBaseUrl = cdnBaseUrlString
                }
            } catch {}
         }
    }
    
    
    internal func postLoadingFromCDN(configDict: [String : Any], delegate: TapCardViewDelegate? = nil) {
        do {
            try openUrl(url: URL(string: generateTapCardSdkURL(from: configDict)))
        }
        catch {
            self.delegate?.onError?(data: "{error:\(error.localizedDescription)}")
        }
    }
    
    /*///  configures the tap card sdk with the needed configurations for it to work
    ///  - Parameter config: The configurations string json format. Recommended, as it will make you able to customly add models without updating
    ///  - Parameter delegate:A protocol that allows integrators to get notified from events fired from Tap card sdk
    ///  - Parameter presentScannerIn: We will need a reference to the controller that we can present from the card scanner feature
    @objc public func initTapCardSDK(configString: String, delegate: TapCardViewDelegate? = nil, presentScannerIn:UIViewController? = nil) {
        self.delegate = delegate
        self.presentScannerIn = presentScannerIn
        openUrl(url: URL(string: generateTapCardSdkURL(from: configString))!)
    }*/
    
    
    //MARK: - Public interfaces
    
    /// Wil start the process of generating a `TapToken` with the current card data
    @objc public func generateTapToken() {
        // Let us instruct the card sdk to start the tokenizaion process
        endEditing(true)
        webView?.evaluateJavaScript("window.generateTapToken()")
    }
    
    private func update(dictionary dict: inout [String: Any], at keys: [String], with value: Any) {

        if keys.count < 2 {
            for key in keys { dict[key] = value }
            return
        }

        var levels: [[AnyHashable: Any]] = []

        for key in keys.dropLast() {
            if let lastLevel = levels.last {
                if let currentLevel = lastLevel[key] as? [AnyHashable: Any] {
                    levels.append(currentLevel)
                }
                else if lastLevel[key] != nil, levels.count + 1 != keys.count {
                    break
                } else { return }
            } else {
                if let firstLevel = dict[keys[0]] as? [AnyHashable : Any] {
                    levels.append(firstLevel )
                }
                else { return }
            }
        }

        if levels[levels.indices.last!][keys.last!] != nil {
            levels[levels.indices.last!][keys.last!] = value
        } else { return }

        for index in levels.indices.dropLast().reversed() {
            levels[index][keys[index + 1]] = levels[index + 1]
        }

        dict[keys[0]] = levels[0]
    }
}
