#!/usr/bin/perl
use FindBin qw($Bin);
use lib "$Bin/libs";

use Time::HiRes;
use LoxBerry::IO;
use LoxBerry::Log;
use warnings;
use strict;
use IO::Socket;
use Scalar::Util qw(looks_like_number);

use Net::MQTT::Simple;
use LoxBerry::JSON::JSONIO;
use Hash::Flatten;
use File::Monitor;

use Data::Dumper;

$SIG{INT} = sub { 
	LOGTITLE "MQTT Gateway interrupted by Ctrl-C"; 
	LOGEND(); 
	exit 1;
};

$SIG{TERM} = sub { 
	LOGTITLE "MQTT Gateway requested to stop"; 
	LOGEND();
	exit 1;	
};


#require "$lbpbindir/libs/Net/MQTT/Simple.pm";
#require "$lbpbindir/libs/Net/MQTT/Simple/Auth.pm";
#require "$lbpbindir/libs/LoxBerry/JSON/JSONIO.pm";

my $cfgfile = "$lbpconfigdir/mqtt.json";
my $credfile = "$lbpconfigdir/cred.json";
my $datafile = "/dev/shm/mqttgateway_topics.json";
my $extplugindatafile = "/dev/shm/mqttgateway_extplugindata.json";
my $json;
my $json_cred;
my $cfg;
my $cfg_cred;

my $nextconfigpoll;
my $mqtt;

# Plugin directories to load config files
my %plugindirs;

# Subscriptions
my @subscriptions;
my @subscriptions_toms;

# Conversions
my %conversions;

# Reset After Send Topics
my %resetAfterSend;

# Do Not Forward Topics
my %doNotForward;

# Hash to store all submitted topics
my %relayed_topics_udp;
my %relayed_topics_http;
my %health_state;
my $nextrelayedstatepoll = 0;

# UDP
my $udpinsock;
my $udpmsg;
my $udpremhost;
my $udpMAXLEN = 10240;
		
# Own MQTT Gateway topic
my $gw_topicbase;

print "Configfile: $cfgfile\n";
while (! -e $cfgfile) {
	print "ERROR: Cannot find config file $cfgfile";
	sleep(5);
	$health_state{configfile}{message} = "Cannot find config file";
	$health_state{configfile}{error} = 1;
	$health_state{configfile}{count} += 1;
}

$health_state{configfile}{message} = "Configfile present";
$health_state{configfile}{error} = 0;
$health_state{configfile}{count} = 0;

my $log = LoxBerry::Log->new (
    name => 'MQTT Gateway',
	filename => "$lbplogdir/mqttgateway.log",
	append => 1,
	stdout => 1,
	loglevel => 7,
	addtime => 1
	
);

LOGSTART "MQTT Gateway started";

LOGINF "KEEP IN MIND: LoxBerry MQTT only sends CHANGED values to the Miniserver.";
LOGINF "If you use UDP Monitor, you have to take actions that changes are pushed.";
LoxBerry::IO::msudp_send(1, 6666, "MQTT", "KEEP IN MIND: LoxBerry MQTT only sends CHANGED values to the Miniserver.");

my %miniservers;
%miniservers = LoxBerry::System::get_miniservers();

# Create monitor to handle config file changes
my $monitor = File::Monitor->new();

read_config();
create_in_socket();
	
# Capture messages
while(1) {
	if(time>$nextconfigpoll) {
		if(!$mqtt->{socket}) {
			LOGWARN "No connection to MQTT broker $cfg->{Main}{brokeraddress} - Check host/port/user/pass and your connection.";
			$health_state{broker}{message} = "No connection to MQTT broker $cfg->{Main}{brokeraddress} - Check host/port/user/pass and your connection.";
			$health_state{broker}{error} = 1;
			$health_state{broker}{count} += 1;
		} else {
			$health_state{broker}{message} = "Connected and subscribed to broker";
			$health_state{broker}{error} = 0;
			$health_state{broker}{count} = 0;
		}
		
		read_config();
		if(!$udpinsock) {
			create_in_socket();
		}
	}
	eval {
		$mqtt->tick();
	};
	
	# UDP Receive data from UDP socket
	eval {
		$udpinsock->recv($udpmsg, $udpMAXLEN);
	};
	if($udpmsg) {
		udpin();
	} 
	
	## Save relayed_topics_http and relayed_topics_udp
	## and send a ping to Miniserver
	if (time > $nextrelayedstatepoll) {
		save_relayed_states();
		$nextrelayedstatepoll = time+60;
		$mqtt->retain($gw_topicbase . "keepaliveepoch", time);
	}
	
	Time::HiRes::sleep($cfg->{Main}{pollms}/1000);
}

sub udpin
{

	my($port, $ipaddr) = sockaddr_in($udpinsock->peername);
	$udpremhost = gethostbyaddr($ipaddr, AF_INET);
	# Skip log for relayed_state requests
	if( $udpmsg ne 'save_relayed_states' ) {
		LOGOK "UDP IN: $udpremhost (" .  inet_ntoa($ipaddr) . "): $udpmsg";
	}
	## Send to MQTT Broker
			
	my ($command, $udptopic, $udpmessage);
	my $contjson;
	
	# Check for json content
	eval {
			$contjson = from_json($udpmsg);
	};
	if($@) {
		# Not a json message
		$udpmsg = trim($udpmsg);
		($command, $udptopic, $udpmessage) = split(/\ /, $udpmsg, 3);
		
	} else {
		# json message
		$udptopic = $contjson->{topic};
		$udpmessage = $contjson->{value};
		$command = is_enabled($contjson->{retain}) ? "retain" : "publish";
	}

	# Check incoming message
	
	if(lc($command) ne 'publish' and lc($command) ne 'retain' and lc($command) ne "reconnect" and lc($command) ne "save_relayed_states") {
		# Old syntax - move around the values
		$udpmessage = trim($udptopic . " " . $udpmessage);
		$udptopic = $command;
		$command = 'publish';
	}
	my $udptopicPrint = $udptopic;
	if($udptopic) {
		utf8::decode($udptopic);
	}
	
	$command = lc($command);
	if($command eq 'publish') {
		LOGDEB "Publishing: '$udptopicPrint'='$udpmessage'";
		eval {
			$mqtt->publish($udptopic, $udpmessage);
		};
		if($@) {
			LOGERR "Catched exception on publishing to MQTT: $!";
		}
	} elsif($command eq 'retain') {
		LOGDEB "Publish (retain): '$udptopicPrint'='$udpmessage'";
		eval {
			$mqtt->retain($udptopic, $udpmessage);
			
			# This code may only work, when the topic is not subscribed anymore (as the gateway receives the publish itself)
			if(!$udpmessage) {
				LOGDEB "Delete $udptopic from memory because of empty message";
				delete $relayed_topics_http{$udptopic};
				delete $relayed_topics_udp{$udptopic};
			}
		};
		if($@) {
			LOGERR "Catched exception on publishing (retain) to MQTT: $!";
		}
	} elsif($command eq 'reconnect') {
		LOGOK "Forcing reconnection and retransmission to Miniserver";
		$nextconfigpoll = 0;
		undef %plugindirs;
		$LoxBerry::IO::mem_sendall = 1;
	} elsif($command eq 'save_relayed_states') {
		# LOGOK "Save relayed states triggered by udp request";
		save_relayed_states();
	} else {
		LOGERR "Unknown incoming UDP command";
	}
	
	# $udpinsock->send("CONFIRM: $udpmsg ");

}


sub received
{
	
	my ($topic, $message) = @_;
	my $is_json = 1;
	my %sendhash;
	my $contjson;
	
	utf8::encode($topic);
	LOGINF "MQTT received: $topic: $message";
	
	
	
	if( is_enabled($cfg->{Main}{expand_json}) ) {
		# Check if message is a json
		eval {
			$contjson = decode_json($message);
		};
		if($@) {
			# LOGDEB "  Not a valid json message";
			$is_json = 0;
			$sendhash{$topic} = $message;
		} else {
			LOGDEB "  Expanding json message";
			$is_json = 1;
			undef $@;
			eval {
			
				my $flatterer = new Hash::Flatten({
					HashDelimiter => '_', 
					ArrayDelimiter => '_',
					OnRefScalar => 'warn',
					#DisableEscapes => 'true',
					EscapeSequence => '#',
					OnRefGlob => '',
					OnRefScalar  => '',
					OnRefRef => '',
				});
				my $flat_hash = $flatterer->flatten($contjson);
				for my $record ( keys %$flat_hash ) {
					my $val = $flat_hash->{$record};
					$sendhash{"$topic/$record"} = $val;
				}
			};
			if($@) { 
				LOGERR "Error on JSON expansion: $!";
				$health_state{jsonexpansion}{message} = "There were errors expanding incoming JSON.";
				$health_state{jsonexpansion}{error} = 1;
				$health_state{jsonexpansion}{count} += 1;
			} 
		}
	}
	else {
		# JSON expansion is disabled
		$is_json = 0;
		$sendhash{$topic} = $message;
	}
	
	# Boolean conversion
	if( is_enabled($cfg->{Main}{convert_booleans}) ) {
		
		foreach my $sendtopic (keys %sendhash) {
			if( $sendhash{$sendtopic} ne "" and is_enabled($sendhash{$sendtopic}) ) {
				#LOGDEB "  Converting $message to 1";
				$sendhash{$sendtopic} = "1";
			} elsif ( $sendhash{$sendtopic} ne "" and is_disabled($sendhash{$sendtopic}) ) {
				#LOGDEB "  Converting $message to 0";
				$sendhash{$sendtopic} = "0";
			}
		}
	} 
	
	# User defined conversion
	if ( %conversions ) {
		foreach my $sendtopic (keys %sendhash) {
			if( defined $conversions{ trim($sendhash{$sendtopic}) } ) {
				$sendhash{$sendtopic} = $conversions{ trim($sendhash{$sendtopic}) };
			}
		}
	}
	
	# Split cached and non-cached data
	# Also "Reset after send" data imlicitely are non-cached
	my %sendhash_noncached;
	my %sendhash_cached;
	my %sendhash_resetaftersend;
	
	foreach my $sendtopic (keys %sendhash) {
		# Generate $sendtopic with / replaced by _ 
		my $sendtopic_underlined = $sendtopic;
		$sendtopic_underlined =~ s/\//_/g;
		
		# Skip doNotForward topics
		if (exists $cfg->{doNotForward}->{$sendtopic_underlined} ) {
			LOGDEB "   $sendtopic (incoming value $sendhash{$sendtopic}) skipped - do not forward enabled";
			if( is_enabled($cfg->{Main}{use_http}) ) {
				# Generate data for Incoming Overview
				$relayed_topics_http{$sendtopic_underlined}{timestamp} = time;
				$relayed_topics_http{$sendtopic_underlined}{message} = $sendhash{$sendtopic};
				$relayed_topics_http{$sendtopic_underlined}{originaltopic} = $sendtopic;
			}
			next;
		}
		
		if (exists $cfg->{Noncached}->{$sendtopic_underlined} or exists $resetAfterSend{$sendtopic_underlined}) {
			LOGDEB "   $sendtopic is non-cached";
			$sendhash_noncached{$sendtopic} = $sendhash{$sendtopic};
			# Create a list of reset-after-send topics, with value 0
			if(exists $resetAfterSend{$sendtopic_underlined}) {
				$sendhash_resetaftersend{$sendtopic} = "0";
			}
		
		} else {
			LOGDEB "   $sendtopic is cached";
			$sendhash_cached{$sendtopic} = $sendhash{$sendtopic};
		}	
	}
	
	# toMS: Evaluate what Miniservers to send to
	my @toMS = ();
	my $idx=0;
	
	# LOGDEB "Topic '$topic', " . scalar(@subscriptions) . " Subscriptions, " . scalar(@subscriptions_toms) . " toms elements";
	
	my $SUBMATCH_FIND = '\+'; 				# Quoted '+'
	my $SUBMATCH_REPLACE = '\[\^\/\]\+'; 		# Quoted '[^/]+'
		
	foreach ( @subscriptions ) {
		my $regex = $_; 
		# LOGDEB "$_ Regex 0: " . $regex;
		
		## Eval + in subscription
		$regex =~ s/$SUBMATCH_FIND/$SUBMATCH_REPLACE/g;
		# LOGDEB "$_ Regex 1: " . $regex;
		$regex =~ s/\\//g;								# Remove quotation
		# LOGDEB "$_ Regex 2: " . $regex;
		
		## Eval # in subscription
		if( $regex eq '#' ) {							# If subscription is only #, this is a "match-all"
			# LOGDEB "-->Regex is #: $regex";
			$regex = ".+";
		} elsif ( substr($regex, -1) eq '#' ) {			# If subscription ends with #, also fully accept the last hierarchy ( topic test is matched by test/# ) 
			$regex = substr($regex, 0, -2) . '.*';
		}
		# LOGDEB "$_ Regex to query: $regex";
		my $re = qr/$regex/;
		if( $topic =~ /$re/ ) {
			@toMS = @{$subscriptions_toms[$idx]};
			LOGDEB "$_ matches $topic, send to MS " . join(",", @toMS);
			last;
		}
		$idx++;
	}
	
	# toMS: Fallback to default MS if nothing found
	if( ! @toMS ) {
		@toMS = ( $cfg->{Main}->{msno} );
		LOGWARN "Incoming topic does not match any subscribed topic. This might be a bug";
		LOGWARN "Topic: $topic";
	}
	
	# Send via UDP
	if( is_enabled($cfg->{Main}{use_udp}) ) {
		
		#LoxBerry::IO::msudp_send_mem($cfg->{Main}{msno}, $cfg->{Main}{udpport}, "MQTT", $topic, $message);
		foreach my $sendtopic (keys %sendhash) {
			$relayed_topics_udp{$sendtopic}{timestamp} = time;
			$relayed_topics_udp{$sendtopic}{message} = $sendhash{$sendtopic};
			$relayed_topics_udp{$sendtopic}{originaltopic} = $topic;
		}	
		
		my $udpresp;
		
		if( $cfg->{Main}{msno} and $cfg->{Main}{udpport} and $miniservers{$cfg->{Main}{msno}}) {
			# Send uncached
			# LOGDEB "  UDP: Sending all uncached values";
			
			foreach( @toMS ) {
				LOGDEB "  UDP: Sending to MS $_";
				$udpresp = LoxBerry::IO::msudp_send($_, $cfg->{Main}{udpport}, "MQTT", %sendhash_noncached);
				if (!$udpresp) {
					$health_state{udpsend}{message} = "There were errors sending values via UDP to Miniserver $_ (via non-cached api).";
					$health_state{udpsend}{error} = 1;
					$health_state{udpsend}{count} += 1;
				}
				
				# Send 0 for Reset-after-send
				if ( scalar keys %sendhash_resetaftersend > 0 ) {
					LOGDEB "  UDP: Sending reset-after-send values (delay ".$cfg->{Main}{resetaftersendms}." ms)";
					Time::HiRes::sleep($cfg->{Main}{resetaftersendms}/1000);
					$udpresp = LoxBerry::IO::msudp_send($_, $cfg->{Main}{udpport}, "MQTT", %sendhash_resetaftersend);
				}
				
				# Send cached
				# LOGDEB "  UDP: Sending all other values";
				$udpresp = LoxBerry::IO::msudp_send_mem($_, $cfg->{Main}{udpport}, "MQTT", %sendhash_cached);
				if (!$udpresp) {
					$health_state{udpsend}{message} = "There were errors sending values via UDP to the Miniserver (via cached api).";
					$health_state{udpsend}{error} = 1;
					$health_state{udpsend}{count} += 1;
				}
			}
		} else {
			LOGERR "  UDP: Cannot send. No Miniserver defined, or UDP port missing";
		}
		
	}
	# Send via HTTP
	if( is_enabled($cfg->{Main}{use_http}) ) {
		# Parse topics to replace / with _ (cached)
		foreach my $sendtopic (keys %sendhash_cached) {
			my $newtopic = $sendtopic;
			$newtopic =~ s/\//_/g;
			$sendhash_cached{$newtopic} = delete $sendhash_cached{$sendtopic};
		}
		# Parse topics to replace / with _ (non-cached)
		foreach my $sendtopic (keys %sendhash_noncached) {
			my $newtopic = $sendtopic;
			$newtopic =~ s/\//_/g;
			$sendhash_noncached{$newtopic} = delete $sendhash_noncached{$sendtopic};
		}
		# Parse topics to replace / with _ (reset-after-send)
		foreach my $sendtopic (keys %sendhash_resetaftersend) {
			my $newtopic = $sendtopic;
			$newtopic =~ s/\//_/g;
			$sendhash_resetaftersend{$newtopic} = delete $sendhash_resetaftersend{$sendtopic};
		}
		
		# Create overview data (cached)
		foreach my $sendtopic (keys %sendhash_cached) {
			$relayed_topics_http{$sendtopic}{timestamp} = time;
			$relayed_topics_http{$sendtopic}{message} = $sendhash_cached{$sendtopic};
			$relayed_topics_http{$sendtopic}{originaltopic} = $topic;
			LOGDEB "  HTTP: Preparing input $sendtopic (using cache): $sendhash_cached{$sendtopic}";
		}
		# Create overview data (non-cached)
		foreach my $sendtopic (keys %sendhash_noncached) {
			$relayed_topics_http{$sendtopic}{timestamp} = time;
			$relayed_topics_http{$sendtopic}{message} = $sendhash_noncached{$sendtopic};
			$relayed_topics_http{$sendtopic}{originaltopic} = $topic;
			LOGDEB "  HTTP: Preparing input $sendtopic (noncached): $sendhash_noncached{$sendtopic}";
		}

		#LOGDEB "  HTTP: Sending as $topic to MS No. " . $cfg->{Main}{msno};
		#LoxBerry::IO::mshttp_send_mem($cfg->{Main}{msno},  $topic, $message);
		
		if( $miniservers{$cfg->{Main}{msno}} ) {
			foreach ( @toMS ) {
				# LOGDEB "  HTTP: Sending all values";
				my $httpresp;
				$httpresp = LoxBerry::IO::mshttp_send($_,  %sendhash_noncached);
				$httpresp = LoxBerry::IO::mshttp_send_mem($_,  %sendhash_cached);
				if ( scalar keys %sendhash_resetaftersend > 0 ) {
					LOGDEB "  HTTP: Sending reset-after-send values (delay ".$cfg->{Main}{resetaftersendms}." ms)";
					Time::HiRes::sleep($cfg->{Main}{resetaftersendms}/1000);
					$httpresp = LoxBerry::IO::mshttp_send($_, %sendhash_resetaftersend);
				}
			}
		} else {
			LOGERR "  HTTP: Cannot send: No Miniserver defined";
		}
		# if (!$httpresp) {
			# LOGDEB "  HTTP: Virtual input not available?";
		# } elsif ($httpresp eq "1") {
			# LOGDEB "  HTTP: Values are equal to cache";
		# } else {
			# foreach my $sendtopic (keys %$httpresp) {
				# if (!$httpresp->{$sendtopic}) {
					# LOGDEB "  Virtual Input $sendtopic failed to send - Virtual Input not available?";
					# $relayed_topics_http{$sendtopic}{error} = 1;
					# $health_state{httpsend}{message} = "There were errors sending values via HTTP to the Miniserver";
					# $health_state{jsonexpansion}{error} = 1;
					# $health_state{jsonexpansion}{count} += 1;
				# }
			# }
		# }
	}
}

sub read_config
{
	my $configs_changed = 0;
	$nextconfigpoll = time+5;
	
	if(!%plugindirs) {
		$configs_changed = 1;
		my @plugins = LoxBerry::System::get_plugins(0, 1);
		foreach my $plugin (@plugins) {
			next if (!$plugin->{PLUGINDB_FOLDER});
			my $ext_plugindir = "$lbhomedir/config/plugins/$plugin->{PLUGINDB_FOLDER}/";
			$plugindirs{$plugin->{PLUGINDB_TITLE}}{configfolder} = $ext_plugindir;
			
			#push @plugindirs, $ext_plugindir;
			$monitor->watch( $ext_plugindir.'mqtt_subscriptions.cfg' );
			$monitor->watch( $ext_plugindir.'mqtt_conversions.cfg' );
			$monitor->watch( $ext_plugindir.'mqtt_resetaftersend.cfg' );
		}
		# Also watch own config
		$monitor->watch( $cfgfile );
		$monitor->watch( $credfile );
		
		# Monitor for plugin changes (installation/update/uninstall) with special treatment
		$monitor->watch( "$lbstmpfslogdir/plugins_state.json", sub {
			# It requires to re-read the plugin database
			LOGINF "Forcing re-read config because of plugin database change  (install/update/uninstall)";
			undef %plugindirs;
			$nextconfigpoll = 0;
		} );

	}
	
	my @changes = $monitor->scan;
	
	if(!defined $cfg or @changes) {
		$configs_changed = 1;
		my @changed_files;
		# Only for logfile
		for my $change ( @changes ) {
			push @changed_files, $change->name;
		}
		LOGINF "Changed configuration files: " .  join(',', @changed_files) if (@changed_files);
	}
	
	if($configs_changed == 0) {
		return;
	}
	
	LOGOK "Reading config changes";
	# $LoxBerry::JSON::JSONIO::DEBUG = 1;

	# Own topic
	$gw_topicbase = lbhostname() . "/mqttgateway/";
	LOGOK "MQTT Gateway topic base is $gw_topicbase";
	
	# Config file
	$json = LoxBerry::JSON::JSONIO->new();
	$cfg = $json->open(filename => $cfgfile, readonly => 1);
	# Credentials file
	$json_cred = LoxBerry::JSON::JSONIO->new();
	$cfg_cred = $json->open(filename => $credfile, readonly => 1);
	
	if(!$cfg) {
		LOGERR "Could not read json configuration. Possibly not a valid json?";
		$health_state{configfile}{message} = "Could not read json configuration. Possibly not a valid json?";
		$health_state{configfile}{error} = 1;
		$health_state{configfile}{count} += 1;
		return;
	} elsif (!$cfg_cred) {
		LOGERR "Could not read credentials json configuration. Possibly not a valid json?";
		$health_state{configfile}{message} = "Could not read credentials json configuration. Possibly not a valid json?";
		$health_state{configfile}{error} = 1;
		$health_state{configfile}{count} += 1;
		return;

	} else {
	
	# Setting default values
		if(! defined $cfg->{Main}{msno}) { $cfg->{Main}{msno} = 1; }
		if(! defined $cfg->{Main}{udpport}) { $cfg->{Main}{udpport} = 11883; }
		if(! defined $cfg->{Main}{brokeraddress}) { $cfg->{Main}{brokeraddress} = 'localhost'; }
		if(! defined $cfg->{Main}{udpinport}) { $cfg->{Main}{udpinport} = 11884; }
		if(! defined $cfg->{Main}{pollms}) { $cfg->{Main}{pollms} = 50; }
		if(! defined $cfg->{Main}{resetaftersendms}) { $cfg->{Main}{resetaftersendms} = 10; }
		
		
		
		LOGDEB "JSON Dump:";
		LOGDEB Dumper($cfg);

		LOGINF "MSNR: " . $cfg->{Main}{msno};
		LOGINF "UDPPort: " . $cfg->{Main}{udpport};
		
		# Unsubscribe old topics
		if($mqtt) {
			eval {
				$mqtt->retain($gw_topicbase . "status", "Disconnected");
				
				foreach my $topic (@subscriptions) {
					LOGINF "UNsubscribing $topic";
					$mqtt->unsubscribe($topic);
				}
			};
			if ($@) {
				LOGERR "Exception catched on unsubscribing old topics: $!";
			}
		}
		
		undef $mqtt;
		
		# Reconnect MQTT broker
		LOGINF "Connecting broker $cfg->{Main}{brokeraddress}";
		eval {
			
			$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
			
			$mqtt = Net::MQTT::Simple->new($cfg->{Main}{brokeraddress});
			
			if($cfg_cred->{Credentials}{brokeruser} or $cfg_cred->{Credentials}{brokerpass}) {
				LOGINF "Login at broker";
				$mqtt->login($cfg_cred->{Credentials}{brokeruser}, $cfg_cred->{Credentials}{brokerpass});
			}
			
			LOGINF "Sending Last Will and Testament"; 
			$mqtt->last_will($gw_topicbase . "status", "Disconnected", 1);
		
			$mqtt->retain($gw_topicbase . "status", "Joining");
			
			@subscriptions = ();
			foreach my $sub_elem ( @{$cfg->{subscriptions}} ) {
				LOGDEB "Subscription " . $sub_elem->{id};
				push( @subscriptions,  $sub_elem->{id} );
			}
			read_extplugin_config();
			
			# Add external plugin subscriptions to subscription list
			foreach my $pluginname ( keys %plugindirs ) {
				if( $plugindirs{$pluginname}{subscriptions} ) {
					push @subscriptions, @{$plugindirs{$pluginname}{subscriptions}};
				}
			}
			
			# Make subscriptions unique
			LOGDEB "Uniquify subscriptions: Before " . scalar( @subscriptions ) . " subscriptions";
			my %subscriptions_unique = map { $_, 1 } @subscriptions;
			@subscriptions = sort keys %subscriptions_unique;
			undef %subscriptions_unique;
			LOGDEB "Uniquify subscriptions: Afterwards " . scalar( @subscriptions ) . " subscriptions";
			
			my @checked_subscriptions;
			LOGINF "Checking subscriptions for invalid entries";
			foreach my $topic (@subscriptions) {
				my $msg = validate_subscription($topic);
				if($msg) {
					LOGWARN "Skipping subscription $topic ($msg)";
				} else {
					push @checked_subscriptions, $topic;
				}
			}
			@subscriptions = @checked_subscriptions;
						
			push @subscriptions, $gw_topicbase . "#";
			
			# Ordering is required for toMS based on number of topics
			LOGINF "Ordering subscriptions by topic level";
			@subscriptions = sort { ($b=~tr/\///) <=> ($a=~tr/\///) } @subscriptions;
			
			# Fill up the subscriptions_toms array;
			my @default_arr = ( $cfg->{Main}->{msno} );
			
			LOGINF "Reading your config about what topics to send to what Miniserver";
			foreach my $sub ( @subscriptions ) {
				my $sub_set;
				foreach my $cfg_sub ( @{$cfg->{subscriptions}} ) {
					if( $sub eq $cfg_sub->{id} ) {
						if( scalar @{$cfg_sub->{toMS}} > 0 ) {
							push @subscriptions_toms, $cfg_sub->{toMS};
							# LOGDEB "Read Subscription $sub: toMS: " . join( ",", @{$cfg_sub->{toMS}});
						} else {
							push @subscriptions_toms, \@default_arr;
							# LOGDEB "Subscription $sub: toMS: " . join( ",", @default_arr) . " (default)";
						}
						$sub_set = 1;
						last;
					}
				}
				if( ! $sub_set ) {
					push @subscriptions_toms, \@default_arr;
					# LOGDEB "No MS set - using " . $cfg->{Main}->{msno} . "(" . join(',', @{$default_arrref}) . ")";
				}
			}
			
			# Re-Subscribe new topics
			foreach my $topic (@subscriptions) {
				LOGINF "Subscribing $topic";
				$mqtt->subscribe($topic, \&received);
			}
		};
		if ($@) {
			LOGERR "Exception catched on reconnecting and subscribing: $@";
			$health_state{broker}{message} = "Exception catched on reconnecting and subscribing: $@";
			eval {
				$mqtt->retain($gw_topicbase . "status", "Disconnected");
			
			};
			$health_state{broker}{error} = 1;
			$health_state{broker}{count} += 1;
			
		} else {
			eval {
				$mqtt->retain($gw_topicbase . "status", "Connected");
			};
			$health_state{broker}{message} = "Connected and subscribed successfully";
			$health_state{broker}{error} = 0;
			$health_state{broker}{count} = 0;
			
		}
		
		# Conversions
		undef %conversions;
		my @temp_conversions_list;
	
		LOGOK "Processing conversions";
		
		LOGINF "Adding user defined conversions";
		push @temp_conversions_list, @{$cfg->{conversions}} if ($cfg->{conversions});
		
		# Add external plugin conversions to conversion list
		LOGINF "Adding plugin conversions";
		foreach my $pluginname ( keys %plugindirs ) {
			if( $plugindirs{$pluginname}{conversions} ) {
				push @temp_conversions_list, @{$plugindirs{$pluginname}{conversions}};
			}
		}
		
		# Parsing conversions
		foreach my $conversion (@temp_conversions_list) {
			my ($text, $value) = split('=', $conversion, 2);
			$text = trim($text);
			$value = trim($value);
			if($text eq "" or $value eq "") {
				LOGWARN "Ignoring conversion setting: $conversion (a part seems to be empty)";
				next;
			}
			if(!looks_like_number($value)) {
				LOGWARN "Conversion entry: Convert '$text' to '$value' - Conversion is used, but '$value' seems not to be a number";
			} else {
				LOGINF "Conversion entry: Convert '$text' to '$value'";
			}
			if(defined $conversions{$text}) {
				LOGWARN "Conversion entry: '$text=$value' overwrites '$text=$conversions{$text}' - You have a DUPLICATE";
			}
			$conversions{$text} = $value;
		}
		undef @temp_conversions_list;
		
		# Reset after send 
		# User defined settings
		LOGINF "Processing Reset After Send";
		undef %resetAfterSend;
		if (exists $cfg->{resetAfterSend}) {
			LOGINF "Adding user defined Reset After Send";
			foreach my $topic ( keys %{$cfg->{resetAfterSend}}) {
				if (LoxBerry::System::is_enabled($cfg->{resetAfterSend}->{$topic}) ) {
					$resetAfterSend{$topic} = 1;
					LOGDEB "ResetAfterSend: $topic";
				}
			}
		}
		LOGINF "Adding plugins Reset After Send";
		foreach my $pluginname ( keys %plugindirs ) {
			if( $plugindirs{$pluginname}{resetaftersend} ) {
				foreach my $topic ( @{$plugindirs{$pluginname}{resetaftersend}} ) {
					# %resetAfterSend = map { $_ => 1 } @{$plugindirs{$pluginname}{resetaftersend}};
					$resetAfterSend{$topic} = 1;
					LOGDEB "ResetAfterSend: $topic (Plugin $pluginname)";
				}
			}
		}
		
		# Do Not Forward
		LOGINF "Processing Do Not Forward";
		undef %doNotForward;
		if (exists $cfg->{doNotForward}) {
			LOGINF "Adding user defined Do Not Forward";
			foreach my $topic ( keys %{$cfg->{doNotForward}}) {
				if (LoxBerry::System::is_enabled($cfg->{doNotForward}->{$topic}) ) {
					$doNotForward{$topic} = 1;
					LOGDEB "doNotForward: $topic";
				}
			}
		}
		
		# Clean UDP socket
		create_in_socket();
	
	}
}


sub read_extplugin_config
{
	return if(!%plugindirs);
	
	foreach my $pluginname ( keys %plugindirs ) {
		my $content;
		@{$plugindirs{$pluginname}{subscriptions}} = () ;
		@{$plugindirs{$pluginname}{conversions}} = ();
		@{$plugindirs{$pluginname}{resetaftersend}} = ();
		$content = LoxBerry::System::read_file( $plugindirs{$pluginname}{configfolder}."mqtt_subscriptions.cfg" );
		if ($content) {
			$content =~ s/\r\n/\n/g;
			my @lines = split("\n", $content);
			@lines = grep { $_ ne '' } @lines;
			$plugindirs{$pluginname}{subscriptions} = \@lines;
		}
		$content = LoxBerry::System::read_file( $plugindirs{$pluginname}{configfolder}."mqtt_conversions.cfg" );
		if ($content) {
			$content =~ s/\r\n/\n/g;
			my @lines = split("\n", $content);
			@lines = grep { $_ ne '' } @lines;
			$plugindirs{$pluginname}{conversions} = \@lines;
		}
		$content = LoxBerry::System::read_file( $plugindirs{$pluginname}{configfolder}."mqtt_resetaftersend.cfg" );
		if ($content) {
			$content =~ s/\r\n/\n/g;
			my @lines = split("\n", $content);
			@lines = grep { $_ ne '' } @lines;
			$plugindirs{$pluginname}{resetaftersend} = \@lines;
		}
	}
	
	unlink $extplugindatafile;
	my $extplugindataobj = LoxBerry::JSON::JSONIO->new();
	my $extplugindata = $extplugindataobj->open(filename => $extplugindatafile);
	$extplugindata->{plugins}=\%plugindirs;
	$extplugindataobj->write();
	undef $extplugindataobj;
	
}



# Checks a subscription topic for validity to Standard (https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)
# Returns a string with the error on error
# Returns undef if ok
sub validate_subscription
{
	my ($topic) = @_;
	
	if (!$topic) { 
		return "Topic empty"; }
	
	if ($topic eq "#") {
		return;
	}
	if ($topic eq "/") {
		return "/ without any topic level not allowed";
	}
	if(length($topic) > 65535) {
		return "Topic too long (max 65535 bytes";
	}
	
	my @parts = split /\//, $topic;
	for ( my $i = 0; $i < scalar @parts; $i++) {
		if ($parts[$i] eq '#' and $i eq (scalar @parts - 1)) {
			return;
		}
		if ($parts[$i] eq '+') {
			next;
		}
		if ( index($parts[$i], "+") != -1 ) {
			return "+ not allowed as string-part of a subtopic";
		}
		if ( index($parts[$i], "#") != -1 ) {
			return "# not allowed in the middle";
		}
	}
	return;
	
}

sub create_in_socket 
{

	undef $udpinsock;
	# sleep 1;
	# UDP in socket
	LOGDEB "Creating udp-in socket";
	$udpinsock = IO::Socket::INET->new(
		# LocalAddr => 'localhost', 
		LocalPort => $cfg->{Main}{udpinport}, 
		# MultiHomed => 1,
		#Blocking => 0,
		Proto => 'udp') or 
	do {
		LOGERR "Could not create UDP IN socket: $@";
		$health_state{udpinsocket}{message} = "Could not create UDP IN socket: $@";
		$health_state{udpinsocket}{error} = 1;
		$health_state{udpinsocket}{count} += 1;
	};	
		
	if($udpinsock) {
		IO::Handle::blocking($udpinsock, 0);
		LOGOK "UDP-IN listening on port " . $cfg->{Main}{udpinport};
		$health_state{udpinsocket}{message} = "UDP-IN socket connected";
		$health_state{udpinsocket}{error} = 0;
		$health_state{udpinsocket}{count} = 0;
	}
}

sub save_relayed_states
{
	#$nextrelayedstatepoll = time + 60;
	
	## Delete memory elements older than one day, and delete empty messages
	
	# Delete udp messages
	foreach my $sendtopic (keys %relayed_topics_udp) {
		if(	$relayed_topics_udp{$sendtopic}{timestamp} < (time - 24*60*60) ) {
			delete $relayed_topics_udp{$sendtopic};
		}
		if( $relayed_topics_udp{$sendtopic}{message} eq "" ) {
			delete $relayed_topics_udp{$sendtopic};
		}
	}
	
	# Delete http message
	foreach my $sendtopic (keys %relayed_topics_http) {
		if(	$relayed_topics_http{$sendtopic}{timestamp} < (time - 24*60*60) ) {
			delete $relayed_topics_http{$sendtopic};
		}
		if( $relayed_topics_http{$sendtopic}{message} eq "" ) {
			delete $relayed_topics_http{$sendtopic};
		}

	}
	
	
	
	
	
	
	# LOGINF "Relayed topics are saved on RAMDISK for UI";
	unlink $datafile;
	my $relayjsonobj = LoxBerry::JSON::JSONIO->new();
	my $relayjson = $relayjsonobj->open(filename => $datafile);

	# Delete topics that are empty
	
	
	
	
	
	
	
	$relayjson->{udp} = \%relayed_topics_udp;
	$relayjson->{http} = \%relayed_topics_http;
	$relayjson->{Noncached} = $cfg->{Noncached};
	$relayjson->{resetAfterSend} = \%resetAfterSend;
	$relayjson->{doNotForward} = \%doNotForward;
	$relayjson->{health_state} = \%health_state;
	$relayjsonobj->write();
	undef $relayjsonobj;

	# # Publish current health state
	# foreach my $okey ( keys %health_state ) { 
		# my $inner = $health_state{$okey};
		# foreach my $ikey ( keys %$inner ) { 
			# LOGDEB $okey . " " . $ikey . " " . $inner->{$ikey};
		# }
	# }
	
	
	
}


END
{
	if($mqtt) {
		$mqtt->retain($gw_topicbase . "status", "Disconnected");
		$mqtt->disconnect()
	}
	
	if($log) {
		LOGEND "MQTT Gateway exited";
	}
}

