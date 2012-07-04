#!/usr/bin/perl -w
use strict;
use warnings;

BEGIN {
    $VERSION     = '0.01';
}

use Time::HiRes;
use Time::Local;
use RPi::GPIO;    # Can be found at https://github.com/nucwin
use POE;          # POE is on CPAN suggest installing cpanminus on the Pi

my $nogpio = 0;   # Disable GPIO and output binary to STDOUT
my $debug  = 0;   # Show trace and debug info

my $pins = {
    sw => 25,
    s  => 9,
    m  => 10,
    h  => 11,
    1  => 17,
    2  => 18,
    4  => 21,
    8  => 22,
    16 => 23,
    32 => 24,
};

POE::Session->create(
    package_states => [
        main => [ qw(
            _start
            clock_boot clock_tick clock_toggle clock_add
        ) ],
    ],
    options => { trace => $debug, debug => $debug },
);

POE::Kernel->run();

sub _start {
    $_[KERNEL]->alias_set('RPi::BinaryClock');
    # view: 0 = seconds, 1 = minutes, 2 = hours
    $_[HEAP]->{view} = 2;  #start view
    $_[HEAP]->{gpio} = RPi::GPIO->new(MODE => 'BCM');
    
    foreach (keys %{ $pins }) {
        my $mode = ($_ eq 'sw')? 'in' : 'out';
        unless($nogpio) {
            $_[HEAP]->{gpio}->setup($pins->{$_}, $mode);
            $_[HEAP]->{gpio}->output($pins->{$_}, 0) if($mode eq 'out');
        }
        $_[HEAP]->{pins}{$_}{mode}  = $mode;
        $_[HEAP]->{pins}{$_}{state} = 0;
        $_[HEAP]->{pins}{$_}{pin}   = $pins->{$_};
    }    
    
    unless($nogpio) {
        die 'Switch Not Found' if($_[HEAP]->{gpio}->input($pins->{sw}) == 0);
    }
    
    $_[KERNEL]->delay_set( 'clock_boot', 0.2, 32 );
    $_[KERNEL]->delay_set( 'clock_boot', 0.4, 16 );
    $_[KERNEL]->delay_set( 'clock_boot', 0.6, 8 );
    $_[KERNEL]->delay_set( 'clock_boot', 0.8, 4 );
    $_[KERNEL]->delay_set( 'clock_boot', 1.0, 2 );
    $_[KERNEL]->delay_set( 'clock_boot', 1.2, 1 );
    $_[KERNEL]->delay_set( 'clock_boot', 1.4, 'h' );
    $_[KERNEL]->delay_set( 'clock_boot', 1.6, 'm' );
    $_[KERNEL]->delay_set( 'clock_boot', 1.8, 's' );

    $_[KERNEL]->delay_set( 'clock_tick', 2.2 );
    $_[KERNEL]->delay_set( 'clock_toggle', 2.2 );
}

sub clock_boot {
    if ( $_[HEAP]->{pins}{$_[ARG0]}{state} == 0 ) {
        unless($nogpio) {
            $_[HEAP]->{gpio}->output($pins->{$_[ARG0]}, 1);
        }
        $_[HEAP]->{pins}{$_[ARG0]}{state} = 1;
        $_[KERNEL]->delay_set(clock_boot => 0.2 => $_[ARG0]);
    }
    else {
        unless($nogpio) {
            $_[HEAP]->{gpio}->output($pins->{$_[ARG0]}, 0);
        }
        $_[HEAP]->{pins}{$_[ARG0]}{state} = 0;
    }
}

sub clock_tick {   
    #turn h/m/s led's off
    unless($nogpio) {
        foreach('h','m','s') {
            if( $_[HEAP]->{pins}{$_}{state} == 1) {
                $_[HEAP]->{gpio}->output($pins->{$_}, 0);
                $_[HEAP]->{pins}{$_}{state} = 0;
            }
        }
    }
    
    my $time = time();
    # 0   1    2    3   4    5 
    #sec,min,hour,mday,mon,year
    my @now = (localtime($time))[0..5];
    
    my @input = split(//,unpack("B32", pack("N", $now[$_[HEAP]->{view}])));
    my @output;
    my @seq = (1,2,4,8,16,32);
    for(my $i = 0; $i <= 5; $i++) {
        my $new = $input[(@input-($i+1))];
        unshift(@output, $new);
        if( $_[HEAP]->{pins}{$seq[$i]}{state} != $new ) {
            die "Error in time output" if($new ne 0 && $new ne 1);
            unless($nogpio) {
                $_[HEAP]->{gpio}->output($pins->{$seq[$i]}, $new);
            }
            $_[HEAP]->{pins}{$seq[$i]}{state} = $new
        }
    }
    if($nogpio) {
        print join(' ', @output)."\n";
    }
    my $newtime = $_[KERNEL]->call('RPi::BinaryClock', 'clock_add', $time);
    $_[KERNEL]->alarm('clock_tick', $newtime);
    
    #turn h/m/s led back on
    unless($nogpio) {
        my @hms = ('s','m','h');
        if( $_[HEAP]->{pins}{$hms[$_[HEAP]->{view}]}{state} == 0) {
            $_[HEAP]->{gpio}->output($pins->{$hms[$_[HEAP]->{view}]}, 1);
            $_[HEAP]->{pins}{$hms[$_[HEAP]->{view}]}{state} = 1;
        }
    }
}

#Polling is a nasty fix for not having interupts in firmware yet (wastes cpu time)
sub clock_toggle {
    return if( $nogpio ); # we dont need this if only testing code
    if( $_[HEAP]->{gpio}->input($pins->{sw}) == 0 ) {
        #Button Pressed
        $_[HEAP]->{view}--;
        $_[HEAP]->{view} = 2 if($_[HEAP]->{view} == -1);
        $_[KERNEL]->alarm('clock_tick');  #clear the next update timer we are going to force update next
        $_[KERNEL]->post('RPi::BinaryClock', 'clock_tick');
        $_[KERNEL]->delay_set('clock_toggle', 0.2);
    } else {
        $_[KERNEL]->delay_set('clock_toggle', 0.1);
    }
}

#Trying to keep cpu usage to a minimum only call clock_tick when update is needed
#for that we need the epoc time for the next update
sub clock_add{
    #seconds are easy
    return ($_[ARG0]+1) if($_[HEAP]{view} == 0);
    
    #Number of days in each month
    my @days = (31,28,31,30,31,30,31,31,30,31,30,31);
    
    # 0   1    2    3   4    5 
    #sec,min,hour,mday,mon,year
    my @now = (localtime($_[ARG0]))[0..5];
    $now[5] += 1900;
    $now[$_[HEAP]{view}]++;
    if($_[HEAP]{view} == 2) {
        $now[1] = 0; #zero the minutes if we are in hours
    }
    $now[0] = 0; #we always want to zero the seconds
    
    # Leap year?
    if($now[5] % 400 == 0) { $days[1]++; }
    elsif($now[5] % 100 == 0) { }
    elsif($now[5] % 4 == 0) { $days[1]++; }
    
    if($now[1] > 59){
        $now[2]++;
        $now[1] = 0;
    }
    if($now[2] > 23){
        $now[3]++;
        $now[2] = 0;
    }
    if($now[3] > $days[$now[4]]){
        $now[4]++;
        $now[3] = 1;
    }
    if($now[4] > 12){
        $now[5]++;
        $now[4] = 0;
    }
    $now[5] -= 1900;
    return timelocal(@now);
}