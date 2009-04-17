require 'rubygems'
require 'right_aws'
require 'mechanize'
require 'ezcrypto'
require 'rand'
require 'yaml'
require 'open-uri'

AWS_ACCESS_KEY_ID = '1GZFKYFWGM2WEAZFZ202'
AWS_SECRET_ACCESS_KEY = 'gcD9Y9FYrJ8XvJptCNVnjG+jdgT+ozLnaV+WHfoC'
AWS_SQS_CRYPTO_KEY = "Hikaru No Go"
AWS_BREAK_QUEUE = 'gm-break'
AWS_READY_QUEUE = 'gm-ready'
NEW_ACCOUNT_URL = "http://www.gmail.com"
CAPTCHA_BUCKET = 'yoshi-eggs-img'

# this makes open-uri behave in all cases.
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

$sqs_connection = RightAws::Sqs.new(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
$sqs_crypto_key = EzCrypto::Key.with_password("Hikaru No Go", "Ashbury & Frederick")
$s3_connection = RightAws::S3.new(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
$bucket = RightAws::S3::Bucket.create($s3_connection, CAPTCHA_BUCKET, true)
$break_queue = $sqs_connection.queue(AWS_BREAK_QUEUE)
$ready_queue = $sqs_connection.queue(AWS_READY_QUEUE)

# return an new web client instance
def new_agent
  agent = WWW::Mechanize.new
  agent.user_agent_alias = 'Mac Safari'
  agent.redirect_ok = true
  agent.set_proxy('localhost', 8085)
  agent
end

# caches the captcha image in the cloud and returns a url for the cached image
def sync_captcha_to_s3 cap_url
  cap_id = rand(31337999).to_s + '.jpg'
  key = RightAws::S3::Key.create($bucket, cap_id)
  open(cap_url, 'User-Agent' => 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)') { |p| key.put(p.read, 'public-read') }
  $bucket.key(cap_id).public_link + "?nocache=#{rand(9999999999)}"
end

def form_inputs form
  keys = form.keys
  values = form.values
  res = {}
  keys.each_with_index { |k, i| res[k] = values[i] }
  res
end

def form_url form
  form.action
end

def get_cookies agent
  agent.cookie_jar.save_as('cookies.yml', :yaml)
  cookie_yaml = ""
  File.open('cookies.yml', 'r') { |f| cookie_yaml = f.read }
  File.delete('cookies.yml')
  cookie_yaml
end

def load_cookies agent, cookie_data
  File.open('cookies.yml', 'w') { |f| f.puts cookie_data }
  agent.cookie_jar.load('cookies.yml', :yaml)
  File.delete('cookies.yml')
  agent
end

# connect to gmail, cache the captcha image
def gmail_account_init first_name, last_name, login, pass
  agent = new_agent
  page = agent.get(NEW_ACCOUNT_URL)
  page = page.links.detect { |l| l.text =~ /Create an account/ }.click  
  remote_captcha_url = page.search('//img')[5].attributes['src']
  local_captcha_url = sync_captcha_to_s3(remote_captcha_url)
  form = page.forms.last
  form.fields.name('FirstName').first.value = first_name
  form.fields.name('LastName').first.value = last_name
  form.fields.name('Email').first.value = login
  form.fields.name('Passwd').first.value = pass
  form.fields.name('PasswdAgain').first.value = pass
  # select frequent flier question
  form.fields.name('selection').first.value = form.fields.name('selection').first.options[1].value
  # choose a random number
  form.fields.name('IdentityAnswer').first.value = rand(31337313).to_s
  cookie_jar = get_cookies(agent)
  rec = [local_captcha_url, {:url => form_url(form), :form => form_inputs(form), :cookies => cookie_jar}]
  $break_queue.send_message($sqs_crypto_key.encrypt64(rec.to_yaml))
  return rec
end

# fill in the correct forms and create the account.
def gmail_account_create 
  rec = YAML.load($sqs_crypto_key.decrypt64($break_queue.pop.to_s))
  puts rec[0]
  cleartext = $stdin.gets.strip
  form_data = rec[1]
  
  form_data[:form]['newaccountcaptcha'] = cleartext
  form_data[:form]['submitbutton'] = 'I accept. Create my account.'
  form_data[:form]['PersistentCookie'] = 'yes'
  agent = new_agent
  load_cookies(agent, form_data[:cookies])
  page2 = agent.post(form_data[:url], form_data[:form])
  if page2.body =~ /The characters you entered/i
    raise "bad captcha".inspect
  end
  raise page2.body.inspect
end

case ARGV.first
when "init" : gmail_account_init("dkjeru", "markffus", "dkjef#{rand(31337)}", "janewayjaneway")
when "create" : gmail_account_create
end
