ICookery
========

ICookery is a IPython notebook kernel developed for [Cookery](https://github.com/mikolajb/cookery).

Tips
----

For testing, it is good to set a lightweight browser to be launched by IPython notebook (I use uzbl) instead of a default one, in order to do it, place the following code in `~/.ipython/profile_default/ipython_notebook_config.py`:

```
import webbrowser

webbrowser.register('uzbl', None, webbrowser.GenericBrowser('uzbl-browser'))
```
