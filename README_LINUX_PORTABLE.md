# Building the Linux portable Uploader V3 package

Build on Ubuntu 20.04 x86_64 or the oldest Ubuntu version you need to support:

```bash
cd uploader/V3
bash packaging/build-linux-portable.sh
```

Output:

```text
dist/uploader-v3-linux-x86_64.tar.gz
dist/uploader-v3-linux-x86_64.sha256
```

On the target machine:

```bash
tar -xzf uploader-v3-linux-x86_64.tar.gz
cd uploader-v3-linux-x86_64
./doctor.sh
./open-editor.sh
./run-pipeline.sh --validate
./run-stage.sh --list
./run-advocate-lookup.sh
./run-stage.sh filing --dry-run
```

The build excludes V1/V2, `.git`, runtime `output/`, pycache files, and live `Data/config.json`. First run copies `app/Data/config.template.json` to `app/Data/config.json`; edit that before live CIS runs.
