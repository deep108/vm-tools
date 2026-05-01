I'm building a MacOS app in a Tart VM. If I want to run it in a simulator on the host, is there an easy-ish way to do that?

-------------

Yes, there's a reasonable workflow for this using Tart's directory sharing and `simctl`. The idea is: build inside the VM, share the build output to the host, then install the `.app` bundle into the host's simulator.

**Step 1 — Share a directory between VM and host**

Start your Tart VM with a shared folder:

```bash
tart run --dir=build-output:~/shared-builds my-vm
```

Inside the guest VM, that folder appears at `/Volumes/My Shared Files/build-output`. The guest needs to be running macOS 13 Ventura or newer for this to work.

**Step 2 — Build for the simulator inside the VM**

In the guest, build targeting the simulator SDK and output to the shared directory:

```bash
xcodebuild -project MyApp.xcodeproj \
  -scheme MyApp \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath /Volumes/My\ Shared\ Files/build-output/DerivedData \
  build
```

The key here is using `-sdk iphonesimulator` so you get a simulator-compatible `.app` bundle (x86_64/arm64 sim slice, not a device build).

**Step 3 — Install and launch on the host simulator**

Back on your host machine, find the `.app` in the shared folder and push it into the simulator:

```bash
# Boot a simulator if one isn't running
xcrun simctl boot "iPhone 16"

# Install the app
xcrun simctl install booted ~/shared-builds/DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app

# Launch it
xcrun simctl launch booted com.yourcompany.MyApp
```

**Caveats to keep in mind:**

The Xcode versions on the VM and host should be the same (or very close), since simulator bundles are sensitive to SDK version mismatches. Also, the shared directory uses virtio-fs, which is fast but can occasionally be finicky with Xcode's build system writing lots of small files — if you hit issues, you could build to a local path in the VM and then copy just the final `.app` bundle to the shared folder.

If you want to streamline this further, you could wrap the whole thing in a small script that SSHs into the VM, triggers the build, and then runs the `simctl` commands on the host side.

Sources:
- [Tart Quick Start & Directory Sharing](https://tart.run/quick-start/)
- [Tart FAQ](https://tart.run/faq/)
- [simctl Command Line Reference](https://www.iosdev.recipes/simctl/)
- [Build and run iOS app on simulator from CLI](https://gist.github.com/jerrymarino/1f9eb6a06c423f9744ea297d80193a9b)
