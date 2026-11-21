# Voice-over and music: licences and recommendation

Read on 2026-11-21 from the primary sources linked below (licence files, model cards, the vendor's own licence text).
This is a working note for the product owners, **not legal advice**. Free, local tools only; no paid or cloud voice.

## Recommendation: subtitle-only

**Ship the video without a voice and without music.** Reasons:

1. The licence of a synthetic voice is decided by the **voice model**, not by the engine, and the popular defaults are the
   wrong ones: the voice Piper's own examples use (`en_US-lessac`) is research-only, and macOS `say` forbids publishing its output.
2. A few voices are clearly allowed (table below), but nobody has **listened** to them for this script. Quality is a
   judgement a person has to make; the audio was not judged by the people who wrote this note.
3. Captions are burned into the picture and shipped as `captions.en.srt`, they work with the sound off (the usual way a
   Product Hunt gallery video is watched), and they carry every word of the script already.

If the owners still want a voice-over, the lowest-risk path is **Piper with `en_US-joe-medium`, `en_US-mike-medium` or
`en_GB-cori-high`**, or Kokoro-82M, after a person has listened to a test clip and approved it. The script is
[NARRATION.md](NARRATION.md); `./build.sh --audio <wav>` muxes the voice (AAC) into the MP4. Do not record anything with macOS `say`.

## Engines and the voices that go with them

| Candidate | Engine / code licence | Licence of the voice model actually used | Commercial use of the audio and use in a posted video | Verdict |
|---|---|---|---|---|
| **Piper** (`piper-tts` 1.8.0, OHF-Voice/piper1-gpl; the older rhasspy/piper is archived) | GPL-3.0-or-later (the old 1.2.0 was MIT). It is the program that is GPL, not the speech it makes | **Per voice.** Piper "makes no license grant of its own over voice models". Each voice card names its dataset licence, and the training chain back to a from-scratch voice counts ([LICENSING.md](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/LICENSING.md), [COMMERCIAL_USE.md](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/COMMERCIAL_USE.md)) | Depends on the voice, rows below | **Usable with a clean voice** |
| &nbsp;&nbsp;`en_US-joe-medium`, `en_US-mike-medium` | | CC0 dataset on a CC0 base | Yes, nothing is asked of you | **Clearly allowed** |
| &nbsp;&nbsp;`en_GB-cori-high` | | Public domain, trained from scratch | Yes | **Clearly allowed** |
| &nbsp;&nbsp;`en_US-kristin`, `norman`, `john`, `ljspeech-high` | | Public domain (LibriVox, LJ Speech) | Yes | **Clearly allowed** |
| &nbsp;&nbsp;`en_GB-jenny_dioco-medium` | | Custom licence: "Commercial use is permitted"; attribution not required for distributed clips; software must call the voice "Jenny" | Yes; its base is Hi-Fi TTS (CC BY 4.0), so credit Hi-Fi TTS to be safe | Allowed |
| &nbsp;&nbsp;`en_GB-alba-medium`, `en_US-kathleen-medium`, `en_US-libritts-high` | | CC BY 4.0 datasets (Alba, Hi-Fi TTS, LibriTTS) | Yes, with credit | Allowed with credit |
| &nbsp;&nbsp;`en_US-lessac-medium` / `high` | | Blizzard 2013 licence: research purposes only, "excludes any commercial purpose" | **No** | **Not allowed** |
| &nbsp;&nbsp;`en_US-ryan-high`, `en_US-hfc_female-medium` | | CC BY-NC-SA 4.0 | **No** (non-commercial) | **Not allowed** |
| &nbsp;&nbsp;`en_US-amy-medium`, `en_US-libritts_r-medium` | | amy: no documented licence; libritts_r: fine-tuned from lessac | Unclear / inherits lessac | Avoid |
| **Kokoro-82M** (`kokoro` 0.9.4, `kokoro-onnx` 0.6.1) | Apache-2.0 (`kokoro`, `misaki`), MIT (`kokoro-onnx`, `espeakng-loader`) | Weights Apache-2.0. Card: "deployed in numerous projects and commercial APIs. We welcome the deployment of the model in real use cases" | Yes. Caveats: the card says part of the training audio was synthetic audio from closed TTS services (effect on downstream use not checked, unverified); CC BY credits (SIWIS, Koniwa tnc) are a cheap precaution. The phonemizer packages (`phonemizer`, `phonemizer-fork`, espeak-ng data) are GPL, which matters only when shipping a program that bundles them, not for the audio | Allowed; 115 to 330 MB model download |
| **espeak-ng** (2.0, apt `espeak-ng`) | GPL-3.0-or-later | None (rule-based synthesis, no recorded voice) | GPLv3 text: output is covered "only if the output ... constitutes a covered work"; a plain WAV is not (inference, not an explicit grant) | Allowed, **but robotic**: the project says it "is not as natural or smooth as larger synthesizers". Not good enough for a product video |
| **macOS `say`** (System Voices) | Apple proprietary | macOS licence section F | **No.** System Voices may be used "for your personal, non-commercial use"; "recording, publishing or redistribution ... in a profit, non-profit, public sharing or commercial context" is not permitted ([macOS licence](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf)) | **Not allowed** for a posted video |
| MeloTTS (MIT code, MIT model card) | MIT | MIT; training-data provenance not stated on the card (unverified) | Licence permits it | Not pursued |
| Coqui XTTS-v2 | CPML | CPML: "allows only non-commercial use of a machine learning model and its outputs" | **No** | Excluded |
| F5-TTS | MIT code | Weights CC-BY-NC-4.0 | **No** | Excluded |

Source pages (all opened 2026-11-21): Piper voice cards `https://huggingface.co/rhasspy/piper-voices/blob/main/en/<locale>/<voice>/<quality>/MODEL_CARD`;
Piper docs above; Blizzard 2013 licence `https://www.cstr.ed.ac.uk/projects/blizzard/2013/lessac_blizzard2013/license.html`;
Kokoro card `https://huggingface.co/hexgrad/Kokoro-82M` and PyPI pages for `kokoro`, `kokoro-onnx`, `misaki`; espeak-ng
`https://github.com/espeak-ng/espeak-ng` (README, `COPYING`); Jenny licence `https://github.com/dioco-group/jenny-tts-dataset`;
Hi-Fi TTS `https://www.openslr.org/109/`; XTTS-v2 `https://huggingface.co/coqui/XTTS-v2`; F5-TTS `https://huggingface.co/SWivid/F5-TTS`.
The Piper voices were retrained in late 2026 and kept their names: take a voice from the current `piper-voices` repository, not from an older copy.

## Music
**None.** The default video has no music track. If one is ever added it must come with a licence file that allows
commercial use and redistribution inside a video (for example CC0 or CC BY with the credit in the video description), and
its source, author and licence must be written into [LICENSES.md](LICENSES.md) in the same change. Nothing is bundled here.

## Test clips
Voice test clips, if any are made, stay in the artifacts folder (never in this repository) and are named by voice, for example
`tts-test-piper-en_US-joe-medium.wav`. See the delivery report for the list.
