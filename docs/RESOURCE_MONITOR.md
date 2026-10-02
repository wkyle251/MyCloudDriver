# App and task resources

Settings → Resources samples this app and its child processes every two seconds.
CPU and resident memory are grouped under the task that owns each helper, across
all open workspaces. A process is counted once. CPU percentages use 100% per core;
resident memory can include shared pages.

The GPU card shows **device utilization across the whole Mac**, including other
apps. Each Metal device is matched by registry ID to its IOAccelerator entry.
The monitor reads the driver's `Device Utilization %` counter using an
[IORegistry property snapshot](https://developer.apple.com/documentation/iokit/1514293-ioregistryentrycreatecfproperty).
Driver counter availability varies. Missing, nonnumeric or out-of-range values
are shown as unavailable; a valid zero means idle. Multiple GPUs are displayed
separately, without summing percentages or mixing rendering-only counters.

Similarity rows also show the backend selected by the running helper: CPU,
checking CoreML, or CPU + CoreML. The job count comes from FileTwin's current
`accelerator_active` and `accelerator_limit` progress fields. It is recorded once
per scan, regardless of the number of child workers. Comparison progress clears
active model counts. A resumed CPU scan remains labelled CPU even if the user's
preference for new scans is Automatic.

CoreML chooses CPU, GPU or Neural Engine execution. Its model-job count describes
task activity. The monitor does not have access to CoreML's internal
[Metal command buffers and GPU timestamps](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime),
so it does not assign the whole Mac's GPU percentage to a particular task or
label shared system GPU activity as MyCloudDriver-only usage.

File → Find Similar Files is available from All Drives. It uses the active
workspace, defaults to Local Disk without requiring sign-in, and keeps the
existing scan's drive when reopening retained work. Other file operations still
require an open drive. The scan window's drive picker includes all four drives.

Validation covers malformed/missing GPU counters, device identity, per-task
attribution, current backend/progress, multiple workspaces and Home command
routing. `ResourcesHomeUITestApp.swift` renders the real Home and Settings views
with a synthetic task and real GPU reading, without account credentials.
