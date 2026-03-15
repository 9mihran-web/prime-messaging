# Prime Messaging Project Structure

## Proposed Xcode Source Layout

```text
PrimeMessaging/
  App/
    PrimeMessagingApp.swift
    AppEnvironment.swift
    AppState.swift
    RootView.swift
  Core/
    DesignSystem/
    Localization/
    Utilities/
  Domain/
    Entities/
    Enums/
    Protocols/
    ValueObjects/
  Data/
    Bluetooth/
    Networking/
    Repositories/
    Storage/
  Features/
    Auth/
    Chat/
    ChatList/
    Home/
    Offline/
    Profile/
    Settings/
  Resources/
    Localization/
Docs/
  ProductFoundation.md
  Architecture.md
  DataSchema.md
  ProjectStructure.md
  ImplementationPlan.md
```

## Why This Structure

- `App/` owns composition, environment wiring, root navigation, and lifecycle entry points.
- `Core/` owns design system, localization helpers, and shared utilities.
- `Domain/` keeps product language stable regardless of backend or UI changes.
- `Data/` isolates repository implementations, cache adapters, network transport, and Bluetooth transport.
- `Features/` keeps screens, feature-specific view models, and local UI composition together.
- `Resources/Localization/` supports Armenian-first internationalization from day one.
- `Docs/` keeps product and engineering decisions near the codebase for early team alignment.

## Suggested Future Growth

When the app outgrows a single target, split into local Swift packages or frameworks:

- `PrimeDomain`
- `PrimeData`
- `PrimeDesignSystem`
- `PrimeFeatures`
- `PrimeTransportOnline`
- `PrimeTransportOffline`

This current structure keeps that migration straightforward.
