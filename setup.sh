# see C:\Users\Pace Heart\Documents/ssh\rhymecrime-oa* for SSH keys
sudo su -
dnf install emacs
dnf install git
dnf install ruby
cd /var/www/cgi-bin/
git clone http://github.com/paceheart/rhymecrime/
gem install rwordnet
gem install rspec
gem install scalpel memery msgpack

# webserver setup
sudo dnf install -y httpd php php-mysqli mariadb105
# do this: https://editrocket.com/articles/ruby_apache_windows.html
# and add this: SetEnv GEM_HOME "/home/daemon/.gem/ruby/2.2.0"
# and add this in the <Directory /> block: RedirectMatch ^/$ http://rhymecrime.com/cgi-bin/bin/rhyme.rb
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
ln -s ../cgi-bin/assets/crimestyle.css
ln -s ../cgi-bin/assets/crimestyle-wide.css

# not sure this is necessary:
cd /var/www/cgi-bin/
sudo chmod o+x bin/*.rb bin/dict-build bin/preprocess-conceptnet-lemma-cache

sudo dnf install xorg-x11-xauth.x86_64 xorg-x11-server-utils.x86_64 dbus-x11.x86_64

# Wiktionary pronunciation + POS + forms + alt/form-of senses (kaikki.org / wiktextract) → corpora/wiktionary/
# The filter logic lives in bin/filter-kaikki so it's easy to re-run when we want
# to pick up additional fields from the raw dump.
mkdir -p corpora/wiktionary
curl -fL "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl" \
  | bin/filter-kaikki \
  | gzip > corpora/wiktionary/kaikki-english-filtered.jsonl.gz

# VarCon (Variant Conversion Info) — hand-verified US/UK/CA/AU spelling-variant clusters maintained
# by the aspell/SCOWL author. Used by lib/rhymecrime/dict/varcon.rb at build time as the authoritative
# source for regional spelling preference, complementing the noisier Wiktionary signal. License is
# BSD-style (see varcon-readme). ~750 KB single file.
mkdir -p corpora/varcon
curl -fL -o corpora/varcon/varcon.txt \
  "https://raw.githubusercontent.com/en-wl/wordlist/v1/varcon/varcon.txt"

# Wordfreq Zipf export → generated/wordfreq.tsv (gitignored; used by dict.rb / dict-build)
# Use `python3 -m pip` so wordfreq installs for the same interpreter as `python3` (asdf/pyenv).
python3 -m pip install --user -r lib/rhymecrime/dict/wordfreq/requirements.txt
mkdir -p generated
python3 lib/rhymecrime/dict/wordfreq/export_wordfreq_tsv.py

# ConceptNet 5.7 assertions (CC-BY-SA 4.0) → corpora/conceptnet/; lemma cache → generated/ (dict-build needs it)
# https://github.com/commonsense/conceptnet5/wiki/Downloads
mkdir -p corpora/conceptnet
curl -fL -o corpora/conceptnet/conceptnet-assertions-5.7.0.csv.gz \
  "https://s3.amazonaws.com/conceptnet/downloads/2019/edges/conceptnet-assertions-5.7.0.csv.gz"
mkdir -p generated
# Lemma list gzip for fast headword intersection (dict-build also auto-builds if missing/stale)
./bin/preprocess-conceptnet-lemma-cache

# ConceptNet Numberbatch 19.08 English (CC-BY-SA 4.0) → corpora/numberbatch/numberbatch-en-19.08.txt (dict-build → numberbatch_vectors.msgpack)
# Official distribution is .txt.gz; gunzip leaves the plain .txt that utils_rhyme.rb expects.
# https://github.com/commonsense/conceptnet-numberbatch#downloads
mkdir -p corpora/numberbatch
curl -fL -o corpora/numberbatch/numberbatch-en-19.08.txt.gz \
  "https://conceptnet.s3.amazonaws.com/downloads/2019/numberbatch/numberbatch-en-19.08.txt.gz"
gunzip -f corpora/numberbatch/numberbatch-en-19.08.txt.gz

