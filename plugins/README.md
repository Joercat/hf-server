# plugins/

The Dockerfile copies everything in this folder into the Paper backend's
`plugins/` directory (`COPY plugins/ /opt/server/backend/plugins/`).

The original Space ships two AuthMe jars here:

* `AuthMe-6.0.1-Bungee.jar`
* `AuthMeBungee-2.2.0-beta1.jar`

They are binary release jars and are **not** committed in this checkout.
Grab them from the Hugging Face Space repository
(`https://huggingface.co/spaces/smodusermc/12/tree/main/plugins`) and drop them
in this folder before building, otherwise the server starts without
authentication.
