# Possible improvements

These are exploratory ideas, not scheduled work.

- **Fuel scheduling:** estimate when a burner might run low from fuel value and
  burn rate, reducing checks while it has sufficient fuel.
- **Combat-aware refills:** use combat activity, such as `on_entity_damaged`, to
  bring active turrets forward for refilling.

The [event notes](EVENTS.md) collect possible signals for these and other ideas.
