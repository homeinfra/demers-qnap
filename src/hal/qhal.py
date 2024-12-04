#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# This script is used to handle the SuperIO chip I/O operations

from collections import namedtuple
import os
import sys
import argparse
import socket
import daemon
import signal
import fcntl

# Define some values for the supported HAL features
LED = namedtuple('IO', ['name', 'port', 'bit', 'desired_state'])
BUTTON = namedtuple('IO', ['name', 'port', 'bit', 'cmd'])
SOUND = namedtuple('SOUND', ['name', 'id'])

# Define the list of LEDs
# Apparently the first two disks have access to a blinking LED, via I2C.
leds = [
    LED(name='Status_Green', port=0x91, bit=2, desired_state=None),
    LED(name='Status_Red', port=0x91, bit=3, desired_state=None),
    LED(name='Front_USB', port=0xE1, bit=7, desired_state=None),
    LED(name='Disk1_Present', port=0xB1, bit=2, desired_state=None),
    LED(name='Disk2_Present', port=0xB1, bit=3, desired_state=None),
    LED(name='Disk1_Error', port=0x81, bit=0, desired_state=None),
    LED(name='Disk2_Error', port=0x81, bit=1, desired_state=None),
    LED(name='Disk3_Error', port=0x81, bit=2, desired_state=None),
    LED(name='Disk4_Error', port=0x81, bit=3, desired_state=None),
    LED(name='Disk5_Error', port=0x81, bit=4, desired_state=None),
    LED(name='Disk6_Error', port=0x81, bit=5, desired_state=None),
]

# Define the list of buttons
buttons = [
    BUTTON(name='Reset', port=0x92, bit=1, cmd=None),
    BUTTON(name='USB_Copy', port=0xE2, bit=2, cmd=None),
]

# Define the list of sounds the buzzer can generate
sounds = [
    SOUND(name='Beep', id=0),
    SOUND(name='Online', id=1),
    SOUND(name='Ready', id=2),
    SOUND(name='Alert', id=3),
    SOUND(name='Outage', id=8),
    SOUND(name='Completed', id=12),
    SOUND(name='Error', id=14),
]

SOCKET_PATH = '/tmp/qhal_daemon.sock'
PID_FILE = '/tmp/qhal_daemon.pid'

def qhal_daemon():
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server_socket:
        server_socket.bind(SOCKET_PATH)
        server_socket.listen()

        while True:
            conn, _ = server_socket.accept()
            with conn:
                data = conn.recv(1024)
                if data:
                    response = handle_command(data.decode())
                    conn.sendall(response.encode())

def handle_command(command):
    parts = command.split()
    cmd = parts[0]
    args = parts[1:]

    if cmd == 'led':
        return handle_led_command(args)
    elif cmd == 'button':
        return handle_button_command(args)
    else:
        return f'Unknown command: {cmd}'

def handle_beep_command(arg):
    if len(arg) <= 1:
        print('Usage: beep <sound>')
        return
    
    # Arguments
    sound = next((s for s in sounds if s.name == arg), None)
    
    os.system(f'qnap_hal hal_app --se_buzzer enc_id=0,mode={sound.id}')

def handle_led_command(args):
    if len(args) != 2:
        return 'Usage: led <enum> <on|off>'
    led_enum = args[0]
    state = args[1]
    # Implement the led command logic here
    return f'LED command executed for {led_enum} with state: {state}'

def handle_button_command(args):
    if len(args) < 1:
        return 'Usage: usb -- <command>'
    usb_command = ' '.join(args)
    # Implement the usb command logic here
    return f'USB command set to: {usb_command}'

def write_pid_file():
    with open(PID_FILE, 'w') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(str(os.getpid()))
        fcntl.flock(f, fcntl.LOCK_UN)

def read_pid_file():
    with open(PID_FILE, 'r') as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        pid = int(f.read().strip())
        fcntl.flock(f, fcntl.LOCK_UN)
    return pid

def start_daemon():
    if os.path.exists(PID_FILE):
        with open(PID_FILE, 'r') as f:
            try:
                pid = int(f.read().strip())
                os.kill(pid, 0)
                print("Daemon is already running")
                return
            except ProcessLookupError:
                print("Stale PID file found. Removing it.")
                os.remove(PID_FILE)

    with daemon.DaemonContext():
        with open(PID_FILE, 'w') as f:
            f.write(str(os.getpid()))
        qhal_daemon()

def stop_daemon():
    if os.path.exists(PID_FILE):
        try:
            pid = read_pid_file()
            os.kill(pid, signal.SIGTERM)
            os.remove(PID_FILE)
            print("Daemon stopped")
        except ProcessLookupError:
            print("Daemon is not running, but PID file exists")
            os.remove(PID_FILE)
    else:
        print("Daemon is not running")

def status_daemon():
    if os.path.exists(PID_FILE):
        with open(PID_FILE, 'r') as f:
            try:
                pid = int(f.read().strip())
                os.kill(pid, 0)
                print("Daemon is running")
            except ProcessLookupError:
                print("Daemon is not running, but PID file exists")
    else:
        print("Daemon is not running")

def main():
    parser = argparse.ArgumentParser(description='''
        QNAP HAL API. Includes a daemon that monitors the hardware.
        Also executes command to control the front pannel''')
    subparsers = parser.add_subparsers(dest='command', help='Command to control the daemon')

    subparsers.add_parser('start', help='Start the daemon')
    subparsers.add_parser('stop', help='Stop the daemon')
    subparsers.add_parser('status', help='Check the status of the daemon')

    beep_parser = subparsers.add_parser('beep', help='Execute beep command')
    beep_parser.add_argument('sound', choices=[s.name for s in sounds], help='Sound to play')

    led_parser = subparsers.add_parser('led', help='Execute LED command')
    led_parser.add_argument('name', choices=[led.name for led in leds], help='LED name')
    led_parser.add_argument('state', choices=['on', 'off'], nargs='?', help='LED state')

    button_parser = subparsers.add_parser('button', help='Set button command')
    button_parser.add_argument('name', choices=[button.name for button in buttons], help='Button name')
    button_parser.add_argument('command', nargs="?", help='Command to execute when the button is pressed')

    args = parser.parse_args()

    if args.command == 'start':
        start_daemon()
    elif args.command == 'stop':
        stop_daemon()
    elif args.command == 'status':
        status_daemon()
    elif args.command == 'beep':
        handle_beep_command(args.sound)
    else:
        command = f"{args.command} {' '.join(args.command)}" if args.command == 'usb' else f"{args.command} {' '.join(vars(args).values())}"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client_socket:
            client_socket.connect(SOCKET_PATH)
            client_socket.sendall(command.encode())
            response = client_socket.recv(1024).decode()
            print(response)

if __name__ == "__main__":
    main()
else:
    raise Exception(f"{__file__} is not a library")