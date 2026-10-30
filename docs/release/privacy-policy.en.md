# MoMo Agent Privacy Policy

Status: pre-release draft. Complete the release tasks in the adjacent `README.md` before publication.

Effective date: TODO (actual publication date)
Developer / personal information controller: TODO (legal name or actual operating entity)
Privacy contact: TODO (working email address)

## Scope

This policy covers the MoMo Agent iPhone and Apple Watch apps: recording on Watch, transfer to the paired phone, on-device transcription and record management, and assistant conversations using a model service you configure. Local recording and transcription do not require a MoMo Agent account or a model API key.

## Information processed locally

- **Audio and recording information:** After you start recording, Apple Watch captures sound and stores audio segments, recording times, markers and transfer status. It transfers recordings to the paired iPhone through WatchConnectivity. Transfer may be delayed.
- **Transcripts and records:** iPhone processes audio locally with the bundled SenseVoiceSmall and Silero VAD models and stores transcripts, timestamps, source references, processing status and related records. This transcription path does not use a cloud transcription service.
- **Conversations and assistant settings:** Conversations, generated content, assistant personality, your profile and long-term memory are stored on the phone. Local assistant tools can update profile and memory in response to your requests; you can also edit or clear these settings.
- **Connection and configuration information:** Device/library identifiers and synchronization state coordinate receipt, retries and deletion across paired devices. These are operational identifiers, not advertising identifiers. Names, model endpoints, model IDs and protocol settings for saved AI service connections are stored on the phone. Each connection uses a separate reference to its API key in the device's system Keychain.

The current app code does not integrate advertising, advertising tracking, a developer-operated account system, or remote analytics/crash reporting. The developer does not receive your recordings or transcripts through those features. Third-party model processing is described below.

## Third-party model services and outgoing information

You configure the assistant's model service and provide your own API key under Settings → AI services. An unconfigured app has no preselected provider or model. You can save multiple connections and choose the active connection. Presets fill only an address and API protocol; they do not select a model or establish a connection. For a custom service, you enter the address and explicitly choose the protocol. After connecting and reading the model catalog, you choose a model or enter its ID, then verify and save it for use. Requests go directly from your phone to the configured endpoint, without a MoMo Agent developer-operated model relay. The provider may charge your account.

Reading the model catalog sends an authenticated request to the service you configure. Model verification sends a small synthetic prompt, a random check value and a tool definition to the selected model to check structured tool calling. These two operations do not read or send your recordings, transcripts or chat history. The returned verification tool call is checked but not executed. Verification may incur a small API charge.

Assistant requests may send:

- Your messages, relevant conversation history, model replies and subsequent tool interactions;
- Assistant personality, profile and long-term memory content;
- Transcript excerpts from a selected recording and automatically selected recent excerpts;
- Recording times, source identifiers, citations, processing status, timezone, request time and related context;
- Text and metadata returned by local recording-list, transcript-search and transcript-reading tools. These tools can access records older than the automatic recent window, including records you did not manually select.

The current initial automatic transcript window covers the preceding two hours; the initial context also includes up to eight recording summaries. These limits do not cap the information available throughout a conversation: history and subsequent tool results can include additional content. Recording and local transcription alone do not automatically initiate model requests. Assistant requests and local playback tools do not automatically upload original audio to the model service.

Your key is sent to the configured service for authentication. The service and its network infrastructure also receive connection information such as your source IP address. Use only trusted endpoints and consult the provider's policies on retention, training, processing locations, deletion and security. Processing locations depend on the service you select and may be outside your country or region. Choosing a preset does not guarantee where its provider processes data. MoMo Agent cannot guarantee identical practices across providers.

## Permissions, exports and device files

The Watch app uses microphone permission for recording. You can revoke this permission in system settings, which prevents further recording. The app provides recording, pause/resume and end controls. Obtain appropriate permission before recording others.

On iPhone, recording details let you export transcripts (Markdown and JSON), audio segments, or both through the system file/share interface. iPhone file sharing and opening documents in place are enabled. People, computers or apps with access to these files may read or copy them. Copies exported to cloud storage or another app are governed by that service's practices.

## Retention, deletion and security

Original audio has a default seven-day retention setting, adjustable from one to 365 days. Eligible audio that has been acknowledged as received and completed processing is removed when the app runs its expiration cleanup. Recordings marked to keep audio are excluded. Expiring audio does not automatically delete transcripts.

You can delete a recording and transcript from recording details. The app cleans related assistant context and sends deletion control information to Watch. Watch-side deletion may be delayed by disconnection or processing failures. Editing or clearing personality/profile/memory does not erase existing conversations or recovering requests. The app does not promise a single control that erases all conversations and keys.

Local deletion cannot retract information already sent to a model provider or remove exported/shared copies. Contact the recipient to request deletion. Avoiding new assistant conversations prevents new user-initiated conversations, but already sent requests, ongoing tool rounds and recoverable requests need separate cancellation and verification. Revoke a key at its provider to invalidate it; uninstalling the app does not guarantee removal of Keychain credentials.

The app uses system sandboxing, HTTPS model endpoint validation and system Keychain storage. iPhone archive files have file-protection and backup-exclusion settings. This does not establish that every assistant file, export or device backup is excluded. We do not promise end-to-end encryption or absolute security. Protect your devices and exported files.

## Contact and updates

Contact the privacy email above about access, correction, deletion, information processing or this policy. Do not include a complete API key or unnecessary recordings in your initial message. We will update this policy when practices change and provide notice and obtain additional consent where required.
