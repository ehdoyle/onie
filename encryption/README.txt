This directory serves as an interface point between
your signing key infrastructure and the build of
ONIE components.

It will hold a MACHINE specific Makefile fragment
that details the keys used for signing, and where
those keys will come from, as well as the location
of a signed shim.

It can also hold locally generated keys for
demonstration purposes.

Customize as necessary.
