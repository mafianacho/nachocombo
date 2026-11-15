import AppKit
import NachoComboCore

/// The app side of the Connections tab (NACHO-239): what `PetConnectionsView` asks of the pet module.
extension NachoPetModule: PetConnectionsHost {
    var trust: GadgetTrust { GadgetTrust.shared }

    var macLinkText: String { state.connector.koreanLabel }

    func connectionsLoad(_ done: @escaping (Result<ConnectorOverview, ConnectorError>) -> Void) {
        session.loadConnectors(completion: done)
    }

    func connectionsAPI(_ body: @escaping (ConnectionsAPI?) -> Void) {
        session.withConnectionsAPI(body)
    }

    func gadgetStates() -> [GadgetSwitchState] {
        GadgetSwitchState.states(from: gadgetStatus?() ?? [:])
    }

    func setGadget(_ id: GadgetID, on: Bool) {
        guard let module = id.moduleID, id != .computer else { return }
        if let hook = userGadget { hook(module, on) } else { _ = perform?(.setGadget(module, on: on)) }
    }

    func permissionGranted(_ permission: OSPermission) -> Bool { ComputerUseModule.hasPermission(permission) }

    func requestPermission(_ permission: OSPermission) { ComputerUseModule.request(permission) }

    func openInBrowser(_ url: URL) {
        // Only web links reach here (`BeginInfo.authorizeURL` is checked by `SafeLink`).
        NSWorkspace.shared.open(url)
    }
}
