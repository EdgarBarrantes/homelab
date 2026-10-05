# Dawarich creates demo@dawarich.app / safepassword on first start. Replace
# that login with DAWARICH_ADMIN_EMAIL and the generated password, only while
# the default password is still set (a changed password is never touched).
user = User.find_by(email: 'demo@dawarich.app')
if user&.valid_password?('safepassword')
  user.update!(email: ENV.fetch('DAWARICH_ADMIN_EMAIL'),
               password: ENV.fetch('DAWARICH_ADMIN_PASSWORD'),
               password_confirmation: ENV.fetch('DAWARICH_ADMIN_PASSWORD'))
  puts "first-login: default login replaced by #{user.email}"
end
