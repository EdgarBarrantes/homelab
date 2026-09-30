# Topology map

An interactive map (D3 force layout) of every device, service and
connection, served as a static site at `https://map.<DOMAIN>`.

Content and renderer are separate: `topology.example.md` describes the
nodes and edges in a small markdown schema (documented at the top of the
file); `index.html` renders it. To map your own setup, copy the example to
`topology.md` in the repo root (gitignored, it will describe your network)
and edit it; `./lab render` publishes it. No build step.
