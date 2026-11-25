<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/brand/brainlife-mark-on-dark.svg">
    <img src=".github/brand/brainlife-mark-on-light.svg" alt="brainlife.io" width="140">
  </picture>
</p>

<h1 align="center">ga-launcher</h1>

<p align="center">
  Start a Jupyter notebook next to your brainlife.io project data.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-active-brightgreen.svg" alt="Status: active">
  <a href="https://brainlife.io"><img src="https://img.shields.io/badge/brainlife.io-site-3b9fd0.svg" alt="brainlife.io"></a>
  <a href="https://brainlife.io/docs"><img src="https://img.shields.io/badge/Docs-brainlife.io%2Fdocs-005981.svg" alt="Documentation"></a>
  <a href="https://doi.org/10.1038/s41592-024-02237-2"><img src="https://img.shields.io/badge/DOI-10.1038%2Fs41592--024--02237--2-e57536.svg" alt="Nature Methods paper"></a>
</p>

## 🧠 At a glance

| | |
|---|---|
| 🧭 **What** | [ABCD-spec](https://github.com/brainlife/abcd-spec) App (`start.sh` / `status.sh` / `stop.sh`) behind the brainlife.io Analysis tab: starts an allowed `jupyter/*` or `brainlife/*` container on a free port with a random token, mounts the project's data and the staged notebook |
| 📦 **Containers** | Images defined in `containers/` (`dipy`, `octave`) |
| 🔌 **Mounts** | Project data, S3 and DANDI (`dandifs.py`) |
| 🕰️ **Last change** | 2026-09-11 |

## 🚀 How it runs

`config.json` names the project, the container (for example `brainlife/ga-dipy:…`), the group and the notebook to stage; see [`config.json.sample`](config.json.sample).

```bash
./start.sh     # validate the container, find a port, start Jupyter with a token
./status.sh
./stop.sh
```

## 🔗 Related

[ga-octave](https://github.com/brainlife/ga-octave) · [pybrainlife](https://github.com/brainlife/pybrainlife) (library used in the notebooks) · [amaretti-next](https://github.com/brainlife/amaretti-next)

## 📚 Citing

If you use brainlife.io in your work, please cite:

> Hayashi S, Caron BA, Heinsfeld AS, et al. brainlife.io: a decentralized and open-source cloud platform to support neuroscience research. *Nature Methods* 21:809–813 (2024). [doi:10.1038/s41592-024-02237-2](https://doi.org/10.1038/s41592-024-02237-2)

## 🤝 Contributing

Issues and pull requests are welcome in this repository. For help using brainlife.io, see the [documentation](https://brainlife.io/docs).

## ⚖️ License

This repository does not include a license file yet.

<p align="center"><sub>brainlife.io · Brain data across scales. One place to analyze, share and publish it. · The University of Texas at Austin</sub></p>
