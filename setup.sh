# see C:\Users\Pace Heart\Documents/ssh\rhymecrime-oa* for SSH keys
sudo su -
dnf install emacs
dnf install git
dnf install ruby
cd /var/www/cgi-bin/
git clone http://github.com/paceheart/rhymecrime/
gem install rwordnet
gem install rspec
# tokenize.rb, collate.rb, WetCorpus / IndexedWetCorpus / semantic-similarity
gem install scalpel memery msgpack

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

# Wiktionary pronunciation + POS + forms data (kaikki.org / wiktextract)
mkdir -p dict/wiktionary
curl -fL "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl" \
  | ruby -rjson -e '
    $stdin.set_encoding("UTF-8")
    $stdin.each_line do |l|
      obj = JSON.parse(l) rescue next
      pos = obj["pos"]; next unless pos
      word = obj["word"]; next unless word
      sounds = obj["sounds"]&.select { |s| s["ipa"] }
      next if sounds.nil? || sounds.empty?
      forms = obj["forms"]&.select { |f| f["form"] && f["tags"] }
      out = { word: word, pos: pos, sounds: sounds.map { |s| { ipa: s["ipa"], tags: s["tags"] } } }
      out[:forms] = forms.map { |f| { form: f["form"], tags: f["tags"] } } if forms && !forms.empty?
      puts JSON.generate(out)
    end
  ' | gzip > dict/wiktionary/kaikki-english-filtered.jsonl.gz

# WET / C4: paths match WetCorpus.rb ($WET_INPUT_FILE_TEMPLATE) and Hugging Face allenai/c4 (en/)
mkdir -p corpus
curl -fL -o corpus/c4-train.00000-of-01024.json.gz \
  "https://huggingface.co/datasets/allenai/c4/resolve/main/en/c4-train.00000-of-01024.json.gz"
gunzip -fk corpus/c4-train.00000-of-01024.json.gz

./tokenize.rb corpus/c4-train.00000-of-01024.json
# [tokenize more shards if desired: corpus/c4-train.00001-of-01024.json, ...]
./collate.rb
# collate.rb runs total_everything, append_everything, and msgpack_everything (no separate total.rb)
