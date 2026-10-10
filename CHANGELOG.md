# Changelog

All notable changes to DirectorLink · UniFi Protect for Control4. Versions follow the `VERSION` file; the driver version Composer compares is in brackets.

## 1.0.1 (1000199) - 2026-10-10

The first release that is not a beta. No installer has reported on it from a real UniFi system yet; field reports are welcome.

### UniFi Protect Camera

- **DirectorLink camera agreement, version 1, complete:** new string variable `DIRECTORLINK_CAMERA_EVENTS`, `Alert=1` for a camera and `Alert=1,Ring=2` for a doorbell (the ids of *Alert* and *Ring* in driver.xml), so DirectorLink 1.10 finds the events without reading driver.xml. It comes after the existing variables (their order never changes) and follows the kind.
- `DIRECTORLINK_CAMERA`, `DIRECTORLINK_CAMERA_KIND` and `DIRECTORLINK_CAMERA_EVENTS` are written on every start, so they are right after a driver update too.
- A camera whose kind is `camera` (Camera Type set to *Camera*) never fires *Ring*.
- Every ring gets a new `LAST_RING`, later than the one before. It is the console's time of the press when that is within two minutes behind and five seconds ahead of the controller's clock, else the controller's time.

### UniFi Protect Hub

- No changes apart from the version number.

### Both

- README, release notes and the Documentation tabs carry the line "DirectorLink is an independent project, not affiliated with Control4 or Snap One."

## 1.0.0-beta.1 (1000001) - 2026-10-05

First release, a **beta**: built on Ubiquiti's published API and tested against recorded API answers, not yet confirmed on a real UniFi system.

### UniFi Protect Hub (`DirectorLink-UniFi-Protect.c4z`)

- Connects to one UniFi console (Dream Machine, UNVR, Cloud Key Gen2+) with an API key through Ubiquiti's official Protect Integration API. No username or password, no private API.
- Refuses UniFi Protect older than 5.3 with a clear message in **Status**, **Last Error** and the log.
- **Add New Cameras** adds every camera and doorbell with its UniFi name; **Update Camera Names** follows renames in UniFi Protect; **Ignored Cameras** skips some.
- A picture server on the controller (port 47080): each camera's pictures, fetched from the console with the key, kept at most one second, answered only with that camera's own random Basic login.
- Live video: hands each camera its RTSP (port 7447) or RTSPS (port 7441) stream, chosen by **Live Video**; switches on missing streams (**Create Streams**).
- Smart detections, motion and doorbell rings from the console's WebSocket `/subscribe/events`; camera changes from `/subscribe/devices`.
- One alerts tile, *Camera Alert* and *Doorbell Ring* events for all cameras, *Console Offline/Online*.
- **Print Diagnostics**: the console, its Protect version, the API's answer for every camera, the WebSocket state and the last 10 events. **Status**, **Event Connection**, **Picture Server** and **Last Error** properties.
- Debug logging of every request and event to Director's driver log, without the API key or stream tokens.
- The API key goes only to the console: a redirect is stopped before it is followed. Notification links carry a 10-minute token, not a camera's login.

### UniFi Protect Camera (`DirectorLink-UniFi-Protect-Camera.c4z`)

- Control4 camera proxy: pictures from the hub's picture server, live video through `GET_STREAM_URLS` (Control4 OS 3.3.2 or newer).
- Doorbells (G4 Doorbell, G4 Doorbell Pro, G6 Entry) are cameras with a ring.
- DirectorLink camera agreement v1: `DIRECTORLINK_CAMERA`, `DIRECTORLINK_CAMERA_KIND`, `LAST_ALERT` + *Alert*, `LAST_RING` + *Ring*.
- Events, variables, conditionals and contacts for person, vehicle, animal, package, face, license plate, line crossing, intrusion and motion; *Sound Detected*.
- Alerts with **Alert On** (any detection / people and vehicles / people only), the hub's alerts switch, snooze and **Hold Time**, so one event alerts once.
- **Test Picture** and **Setup Report**.
