# see C:\Users\Pace Heart\Documents/ssh\rhymecrime-oa* for SSH keys
sudo su -
dnf install emacs
dnf install git
dnf install ruby
cd /var/www/cgi-bin/
git clone http://github.com/paceheart/rhymecrime/
gem install rwordnet
gem install rspec

# webserver setup
sudo dnf install -y httpd php php-mysqli mariadb105
# do this: https://editrocket.com/articles/ruby_apache_windows.html
# and add this: SetEnv GEM_HOME "/home/daemon/.gem/ruby/2.2.0"
# and add this in the <Directory /> block: RedirectMatch ^/$ http://rhymecrime.com/cgi-bin/rhyme.rb
# to this file: /etc/httpd/conf/httpd.conf
sudo systemctl start httpd
sudo systemctl enable httpd
sudo usermod -a -G apache ec2-user
exit # then log back in
sudo chown -R ec2-user:apache /var/www
sudo chmod 2775 /var/www
find /var/www -type d -exec sudo chmod 2775 {} \;
find /var/www -type f -exec sudo chmod 0664 {} \;
cd /var/www/html/
ln -s ../cgi-bin/html/crimestyle.css
ln -s ../cgi-bin/html/crimestyle-wide.css

# not sure this is necessary:
cd /var/www/cgi-bin/
sudo chmod o+x *

sudo dnf install xorg-x11-xauth.x86_64 xorg-x11-server-utils.x86_64 dbus-x11.x86_64
