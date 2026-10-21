# Mounted into NetAlertX's /app (first on its PYTHONPATH, so Python loads it
# at every start). NetAlertX's API server listens on 0.0.0.0, which with
# host networking means the LAN; its own nginx reaches it at 127.0.0.1, so
# this makes Flask listen on NETALERTX_API_HOST instead. Flask is patched
# only when something imports it, so the scan plugins don't pay for it.
import importlib.abc
import importlib.machinery
import os
import sys

HOST = os.environ.get("NETALERTX_API_HOST")


class _FlaskOnHost(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != "flask":
            return None
        sys.meta_path.remove(self)
        spec = importlib.machinery.PathFinder.find_spec(name, path)
        if spec is None:
            return None
        exec_module = spec.loader.exec_module

        def exec_and_patch(module):
            exec_module(module)
            run = module.Flask.run

            def run_on_host(app, host=None, port=None, *args, **kwargs):
                return run(app, HOST, port, *args, **kwargs)

            module.Flask.run = run_on_host

        spec.loader.exec_module = exec_and_patch
        return spec


if HOST:
    sys.meta_path.insert(0, _FlaskOnHost())
