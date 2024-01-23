import RxSwift
import RxBluetoothKit

enum AlcoholServiceConnectState {
    case connecting
    case connected(Peripheral?)
    case disconnected(Result<RxBluetoothKitService.Disconnection, Error>)
    case failConnect(Error)
    case timeout
}

enum AlcoholServiceByteData: Int {
    case battery = 1
    case usageCount = 2
    case alcoholContent = 4
    case address = 18
}

class AlcoholService {
    
        // MARK: - Public outputs
    
    public var bluetoothState: Observable<BluetoothState> {
        return bluetoothService.stateOutput
    }
    public var state: BluetoothState {
        return bluetoothService.state
    }
    public var scannedPeripheral: Observable<Result<ScannedPeripheral, Error>> {
        return bluetoothService.scanningOutput
    }
    public var connectStatusChange = PublishSubject<AlcoholServiceConnectState>()
    public var deviceMacAddress = PublishSubject<String?>()
    public var alcoholContent = PublishSubject<Float>()
    public var deviceUsageCount = PublishSubject<Int16>()
    public var deviceBattery = PublishSubject<UInt8>()
    
    func startScan(timeout: Int = 4) {
        bluetoothService.startScanning()
    }
    
    func stopScan() {
        bluetoothService.stopScanning()
    }
    
    func connectTo(_ peripheral: Peripheral, timeout: TimeInterval = 30) {
        bluetoothService.discoverServices(for: peripheral)
        onDeviceConnecting()
        timer = Timer.scheduledTimer(timeInterval: timeout, target: self, selector: #selector(onDeviceConnectionTimedOut), userInfo: nil, repeats: false)
    }
    
    func disconnect(_ peripheral: Peripheral) {
        bluetoothService.disconnect(peripheral)
    }
    
        // MARK: - Private Properties
    private let bluetoothService = RxBluetoothKitService()
    private let disposeBag = DisposeBag()
    private var timer: Timer?
    
    init() {
        initializeSubscribers()
    }
    
    private func initializeSubscribers() {
        subscribeDeviceConnected()
        subscribeDeviceDisconnected()
        subscribeValueOutput()
    }
}


    // MARK: - Receive connection status
private extension AlcoholService {
    private func onDeviceConnecting() {
        connectStatusChange.onNext(.connecting)
    }
    
    private func onDeviceConnected(_ peripheral: Peripheral?) {
        connectStatusChange.onNext(.connected(peripheral))
        timer?.invalidate()
        timer = nil
    }
    
    private func onDeviceDisconnected(_ result: Result<RxBluetoothKitService.Disconnection, Error>) {
        connectStatusChange.onNext(.disconnected(result))
        timer?.invalidate()
        timer = nil
    }
    
    private func onDeviceConnectionFailed(_ error: Error) {
        connectStatusChange.onNext(.failConnect(error))
        timer?.invalidate()
        timer = nil
    }
    
    @objc private func onDeviceConnectionTimedOut() {
        connectStatusChange.onNext(.timeout)
    }
}


    // MARK: - Receive data
private extension AlcoholService {
    
    private func getValue(of data: Data?) {
        guard let data = data,
              let service = AlcoholServiceByteData(rawValue: data.count)
        else { return }
        
        switch service {
            case .battery:
                let value = data[0]
                deviceBattery.onNext(value)
            case .usageCount:
                let value = Int16(bigEndian: data.withUnsafeBytes { $0.load(as: Int16.self) })
                deviceUsageCount.onNext(value)
            case .alcoholContent:
                let value =  data.withUnsafeBytes { $0.load(as: Float.self) }
                alcoholContent.onNext(value)
            case .address:
                let value = String(data: data, encoding: .utf8)
                deviceMacAddress.onNext(value)
        }
    }
}


    // MARK: - Subscribers
private extension AlcoholService {
        // MARK: - Discovering Services
    private func subscribeDeviceConnected() {
        bluetoothService.discoveredServicesOutput
            .asObservable()
            .subscribe(onNext: { [weak self] result in
                switch result {
                    case .success(let primaryService):
                        if let service = primaryService.first {
                            self?.bluetoothService.discoverCharacteristics(for: service)
                            self?.onDeviceConnected(service.peripheral)
                        }
                    case .failure(let error):
                        self?.onDeviceConnectionFailed(error)
                }
            }, onError: { error in
                self.onDeviceConnectionFailed(error)
            }).disposed(by: disposeBag)
    }
    
    
        // MARK: - Read Value
    private func subscribeValueOutput() {
        bluetoothService.discoveredCharacteristicsOutput
            .asObservable()
            .subscribe(onNext: { [weak self] result in
                switch result {
                    case .success(let secondaryService):
                        for element in secondaryService {
                            self?.bluetoothService.readValueFrom(element)
                        }
                    case .failure(let error):
                        self?.onDeviceConnectionFailed(error)
                }
            }, onError: { error in
                self.onDeviceConnectionFailed(error)
            }).disposed(by: disposeBag)
        
        bluetoothService.readValueOutput
            .asObservable()
            .subscribe(onNext: { [weak self] result in
                self?.handleValueOutput(result)
            }, onError: { error in
                self.onDeviceConnectionFailed(error)
            }).disposed(by: disposeBag)
    }
    
    private func subscribeDeviceDisconnected() {
        bluetoothService.disconnectionReasonOutput
            .asObservable()
            .subscribe(onNext: { [weak self] result in
                self?.onDeviceDisconnected(result)
            }, onError: { error in
                self.onDeviceConnectionFailed(error)
            }).disposed(by: disposeBag)
    }
    
    private func handleValueOutput(_ result: Result<Characteristic, Error>) {
        switch result {
            case .success(let service):
                if service.value?.count == AlcoholServiceByteData.address.rawValue {
                    self.getValue(of: service.value)
                }
                
                service.observeValueUpdateAndSetNotification()
                    .asObservable()
                    .subscribe(onNext: { [weak self] result in
                        self?.getValue(of: result.value)
                    }, onError: { error in
                        self.onDeviceConnectionFailed(error)
                    }).disposed(by: disposeBag)
                
            case .failure(let error):
                self.onDeviceConnectionFailed(error)
        }
    }
}
