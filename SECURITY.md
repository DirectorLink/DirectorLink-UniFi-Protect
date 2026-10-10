# Security policy

## Reporting a vulnerability

Please report security problems privately, not in public issues.

Open this repository's **Security** tab and choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers see your report.

Include what you found, the driver versions (**Driver Version** in Composer), and the steps to reproduce it. Leave out real API keys, addresses and names.

We will confirm the report, fix the problem in a new release, and credit you if you wish.

## Supported versions

Only the [latest release](../../releases/latest) gets security fixes.

## Scope

The drivers run on the Control4 controller and talk only to the UniFi console you enter, through Ubiquiti's official Protect Integration API.

- **The API key** is kept in the Control4 project (a masked property of the hub). It is sent only to the configured console, in the `X-API-Key` header. A redirect stops the request before it is followed (the key would travel with it), and every log line passes through a filter that hides it.
- **Pictures** are served by the hub on the controller (port 47080 by default) to the home network. Each camera has its own random Basic login, stored in its Control4 camera page. A request with another camera's login, or without a login, is refused. A notification's live-snapshot link carries a token that opens that one camera's picture for 10 minutes, instead of the login.
- **Live video** is the console's own stream (RTSP on port 7447, or RTSPS on 7441). Its URL contains a token that works as a password: the drivers never log it and keep it encrypted.
