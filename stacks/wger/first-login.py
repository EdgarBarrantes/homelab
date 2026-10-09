# Run by the worker before it starts (manage.py shell < this file): wger
# creates "admin" / "adminadmin" on its first start; swap in the generated
# WGER_ADMIN_PASSWORD, only while that default still works.
import os

from django.contrib.auth.models import User

u = User.objects.filter(username='admin').first()
if u and u.check_password('adminadmin'):
    u.set_password(os.environ['WGER_ADMIN_PASSWORD'])
    u.save()
    print('wger: admin password replaced')
