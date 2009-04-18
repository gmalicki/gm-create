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
  agent.set_proxy 'localhost', 8085
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

def form_data_and_cleartext
  retry_count = 0
  rec = []
  begin
    rec = YAML.load($sqs_crypto_key.decrypt64($break_queue.pop.to_s))
  rescue
    retry_count +=1 
    if retry_count < 5
      sleep 3
      retry
    else
      puts "no post is ready, run init first."
      exit
    end
  end
  puts rec[0]
  cleartext = $stdin.gets.strip
  return [rec[1], cleartext]
end

def sync_page agent, page, first_name, last_name, login, pass
  # grab the cookies
  cookie_jar = get_cookies(agent)
  # grab the captcha
  remote_captcha_url = page.search('//img')[5].attributes['src']
  local_captcha_url = sync_captcha_to_s3(remote_captcha_url)
  # grab the form
  form = page.forms.last
  rec = [local_captcha_url, {
    :url => form_url(form), 
    :form => form_inputs(form), 
    :cookies => cookie_jar,
    :first_name => first_name,
    :last_name => last_name,
    :login => login,
    :pass => pass
    }]
  # send it all to the message queue
  $break_queue.send_message($sqs_crypto_key.encrypt64(rec.to_yaml))
  nil
end

def navigate_to_create_account(agent)
  agent.get(NEW_ACCOUNT_URL).links.detect { |l| l.text =~ /Create an account/ }.click
end

# connect to gmail, cache the captcha image
def init_account first_name, last_name, login, pass
  agent = new_agent
  page = navigate_to_create_account(agent)
  form = page.forms.last
  # select frequent flier question
  form.fields.name('selection').first.value = form.fields.name('selection').first.options[1].value
  # choose a frequent flier number
  form.fields.name('IdentityAnswer').first.value = rand(31337313).to_s
  # sync the captchas, cookies, and form
  sync_page(agent, page, first_name, last_name, login, pass)
end

# fill in the correct forms and create the account.
def create_account
  form_data, cleartext = form_data_and_cleartext
  form_data[:form]['FirstName']         = form_data[:first_name]
  form_data[:form]['LastName']          = form_data[:last_name]
  form_data[:form]['Email']             = form_data[:login]
  form_data[:form]['Passwd']            = form_data[:pass]
  form_data[:form]['PasswdAgain']       = form_data[:pass]
  form_data[:form]['newaccountcaptcha'] = cleartext
  form_data[:form]['submitbutton']      = 'I accept. Create my account.'
  form_data[:form]['PersistentCookie']  = 'yes'
  agent = new_agent
  load_cookies(agent, form_data[:cookies])
  puts agent.cookie_jar.inspect
  puts form_data.inspect
  page = agent.post(form_data[:url], form_data[:form])
   if page.body =~ /The characters you entered/i
     puts "incorrect captcha, retrying"
     sync_page(agent, page, form_data[:first_name], form_data[:last_name], form_data[:login], form_data[:pass])
     create_account
   elsif page.body =~ /Type the characters/i
     puts "another attempted requried, retrying"
     sync_page(agent, page, form_data[:first_name], form_data[:last_name], form_data[:login], form_data[:pass])
     create_account
   else
     raise page.body.inspect
   end
end

case ARGV.first
when "init" : init_account("dkdffu", "mefdfus", "dfjkd#{rand(31337)}", "janewayjaneway")
when "create" : create_account
end