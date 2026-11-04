# Model weights (not in git — download once)

## tracknet_tennis.pt (43 MB, required)
Tennis ball heatmap detector (TrackNet architecture, 3-frame input).
Published weights from the unofficial TrackNet implementer for trying
the model: https://github.com/yastrebksv/TrackNet

Download (~43 MB):

```sh
.venv/bin/python -c "import gdown; gdown.download('https://drive.google.com/uc?id=1XEYZ4myUN7QT-NeBYJI0xteLsvs-ZAOl', 'models/tracknet_tennis.pt', quiet=False)"
```

The network code in `tennis_ai/tracknet.py` is our own implementation
of the published TrackNet idea (Huang et al., arXiv:1907.03698); only
the weight values come from that checkpoint.

## ball_best.pt (6 MB, optional)
YOLOv8n fine-tuned for tennis balls (Apache-2.0):
https://huggingface.co/RJTPP/tennis-ball-detection

```sh
curl -sL -o models/ball_best.pt https://huggingface.co/RJTPP/tennis-ball-detection/resolve/main/best.pt
```

Currently used for exploration only; the pipeline tracks from the
TrackNet heatmaps, which handle small/blurry balls better.
